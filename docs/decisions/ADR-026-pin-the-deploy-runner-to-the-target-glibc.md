# ADR-026: Pin The Deploy Runner To An Image The Target's glibc Can Execute

## Status

Accepted

## Date

2026-08-24

Amends [ADR-025](ADR-025-build-releases-in-github-actions.md), which remains accepted.
ADR-025 settled *that* the release is built in GitHub Actions and shipped to the VM; that decision is unchanged.
This ADR replaces one bullet of it - the build/target compatibility constraint - which was stated incorrectly and caused an outage.

## Context

ADR-025 recorded the compatibility constraint as:

> The build runner's OS and architecture must be compatible with the VM's (`ubuntu-latest` x86_64 targeting a same-or-newer Ubuntu x86_64 VM).

Two things were wrong with that sentence.

**The target is not Ubuntu, and it is not newer than the runner.**
The production VM is:

```
Debian GNU/Linux 12 (bookworm)
ldd (Debian GLIBC 2.36-9+deb12u14) 2.36
x86_64
```

**"Compatible OS" is not the constraint; the ABI the release is built against is.**
`mix release` bundles ERTS, so the VM needs no Erlang or Elixir - but the bundled `beam.smp` is a dynamically linked binary against the *build* machine's glibc.
glibc is forward-compatible only: a binary built against 2.39 runs on 2.39 and later, never on 2.36.
The distribution name is not what has to match; the version numbers are what has to order correctly.

glibc is the axis that caused this outage, but it is not the only ABI the release inherits from the build machine.
The bundled ERTS also carries the crypto NIF, which links the *runner's* OpenSSL soname: an image with an older glibc but `libcrypto.so.1.1` (Ubuntu 20.04, say) satisfies the glibc ordering against this VM and would still fail to start on it, because Debian 12 ships `libssl3` and no `libssl1.1`.
glibc and the OpenSSL soname are therefore the axes this decision has **checked** - not a claim that they are the complete set of axes that exist.
Anyone re-pinning should look for further ones rather than trust that this list closes the question; writing a partial check down as though it were exhaustive is precisely the defect ADR-025's bullet had.

The runner's glibc is set by the runner image, and it propagates twice: `erlef/setup-beam` downloads the prebuilt OTP matching the image (the failing run logged `Installing Erlang/OTP OTP-27.3.4.16 - built on amd64/ubuntu-24.04`), and anything compiled on the runner links against the same libc.

`ubuntu-latest` is a floating label. It pointed at Ubuntu 20.04, then 22.04, now 24.04, and Ubuntu 26.04 is already in preview.
Nothing in the repository was watching it move.

### What actually happened

Deploy run `32682797726` (2026-08-24) resolved `ubuntu-latest` to `Image: ubuntu-24.04` (glibc 2.39), built cleanly, uploaded the tarball, unpacked it on the VM, and died at the migration step:

```
beam.smp: /lib/x86_64-linux-gnu/libm.so.6: version `GLIBC_2.38' not found
beam.smp: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
deploy: error: migration failed; /opt/notable/current was left untouched
```

The deploy machinery behaved correctly throughout. Migrations run before the symlink swap, so `current` was never repointed, the never-activated release was removed, and the live service was not touched by the failed deploy. The only defect was the build environment.

The failure was invisible until it reached production because `test/notable/deploy/deploy_workflow_test.exs` asserted `runs-on: ubuntu-latest` - the suite *required* the broken configuration, and pinned the wrong axis: a specific floating image rather than the property that image had to satisfy.

## Decision

**No ABI the deploy runner builds against may exceed what the deployment target provides, and the runner image must be pinned explicitly - never a floating `-latest` label.**

The ABI axes verified to matter so far, and the form the rule takes on each:

- **glibc** - the runner's must be `<=` the target's, because glibc is forward-compatible only.
- **OpenSSL soname** - the runner's must be one the target actually ships, because sonames do not order.

That is what has been checked, not a statement that nothing else applies. The rule is the general one above; these two are its verified instances, and a re-pin should test the new image against both *and* look for axes nobody has hit yet.

Concretely, today:

- `.github/workflows/deploy.yml` pins `runs-on: ubuntu-22.04` (glibc 2.35 <= 2.36; `libcrypto.so.3`, which the VM provides), with an in-file comment giving the reason, the target, the outage, and the fact that the pin expires.
- The deployment target of record is **Debian 12 (bookworm), glibc 2.36, x86_64, `libssl3` 3.0.20-1~deb12u2 and no `libssl1.1` - so `libcrypto.so.3`**. It is written down in `docs/OPERATIONS.md` and in the test, because it is what the pin is derived from.
- `test/notable/deploy/deploy_workflow_test.exs` asserts the invariant, not the image: `runs-on` is explicitly versioned, is not `-latest`, maps to a glibc `<=` the target's, and maps to an OpenSSL soname the target provides. An image the test has no verified values for fails rather than passing unchecked, so pinning a new one forces someone to look them up.
- The same test asserts that exactly one workflow builds a release, so the constraint cannot quietly apply to a workflow nobody pinned.

Scope of the rule:

- `.github/workflows/rollback.yml` compiles nothing and produces no artifact the VM executes - it swaps a symlink over SSH - so its runner image is not load-bearing. It is pinned only so both halves of the deployment path move together, and its comment says exactly that.
- `.github/workflows/ci.yml` may keep floating on `ubuntu-latest`. It runs the quality gate and ships nothing to the VM.

**This pin is a maintenance obligation, not a fix that stays fixed.**
GitHub retires runner images - `ubuntu-20.04` is already gone from the `actions/runner-images` table - and Ubuntu 22.04 leaves standard LTS support in April 2027.
When `ubuntu-22.04` is retired, the choice is: pick the newest available image that still satisfies the rule on every axis known at that point, upgrade the VM's Debian release and then the runner, or remove the dependency entirely (below).
The rule survives that change; the image does not.

## Alternatives Considered

### Assert `runs-on: ubuntu-22.04` in the drift guard

- Pros: one-line change, obviously matches today's workflow.
- Cons: reproduces the exact bug it is meant to prevent, one image later. The old assertion was not wrong because it named 24.04's predecessor; it was wrong because it named an image at all.
- Rejected: the test now asserts the property.

### Build inside a container matching the target (`hexpm/elixir:<ver>-erlang-<ver>-debian-bookworm-*`)

- Pros: removes the runner-image dependency entirely. The build's ABI becomes the *target's* ABI by construction - on glibc, on the OpenSSL soname, and on any axis nobody has thought to check - so it cannot drift when GitHub moves `ubuntu-latest` or retires an image, and it stays correct without anyone remembering this ADR.
- Cons: a second version axis to keep in step with `ci.yml`'s Elixir/OTP pins, and the release would then be built on a different toolchain image than the one CI's quality gate ran on unless CI moves too.
- Not rejected - deferred. It is the durable answer and worth doing, but the captain needs a deploy that works now, and the pin is verifiable by reasoning that holds today. Revisit at the latest when `ubuntu-22.04` is retired, when the decision has to be made anyway.

### Set `include_erts: false` and install Erlang on the VM

- Pros: the release stops carrying a glibc-linked ERTS, so the build image stops mattering.
- Cons: reintroduces exactly what ADR-025 removed - an Erlang/Elixir toolchain to install and keep current on a 1 GB free-tier box - and moves the version-skew risk from build time to runtime.
- Rejected: ADR-025's reasoning for a self-contained release still holds.

### Rebuild the VM on a newer distribution

- Pros: lets the build track `ubuntu-latest` again.
- Cons: a live machine taking real payments, rebuilt to work around a one-line pin, and it only buys time - `ubuntu-latest` keeps moving, so the same race resumes on the next release.
- Rejected.

## Consequences

- Deploys build on `ubuntu-22.04` and produce a release the VM can execute.
- The deployment target's OS, glibc, and OpenSSL soname are now recorded facts in `docs/OPERATIONS.md`, not assumptions. Changing the VM's distribution now requires updating `@target_glibc` and `@target_libcrypto` in the deploy workflow test, which will fail loudly if the pin no longer satisfies them.
- A future runner-image retirement will break Deploy. It will break it at build time, before anything reaches the VM, and the in-file comment plus this ADR say what to do about it.
- ADR-025 stands, minus the one bullet this ADR replaces.
