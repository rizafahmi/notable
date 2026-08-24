# Milestone 16 - Deployment automation

Issue: [#37](https://github.com/rizafahmi/notable/issues/37) - set up better deployment automation.

## Starting state (found, not assumed)

Verified against `origin/main` (`b1d447e`).

- [ADR-019](../../decisions/ADR-019-deployment-strategy-gcp-free-tier-releases.md) already settled the runtime shape: single Linux VM, `mix release`, `systemd`, a `current` symlink for rollback, SQLite as a file at `DATABASE_PATH`, no containers.
- `docs/OPERATIONS.md` held a manual checklist plus an **example** systemd unit and directory layout. The example values (`/opt/notable/current`, `/etc/notable/notable.env`, user `notable`) were illustrative, not verified facts about the real machine.
- `lib/notable/release.ex`, `rel/overlays/bin/migrate`, and `rel/overlays/bin/server` existed and were correct.
- `.github/workflows/ci.yml` ran `mix ci` plus the OpenCV QR-decode tests. It never deployed.
- The app was already live on a VM serving real traffic and real payments.

What ADR-019 did **not** settle: where the release gets built, and what triggers a deploy.
The manual checklist told operators to run `MIX_ENV=prod mix release` on the VM itself.

## Constraints this milestone worked under

No credentials for the live machine, and none were sought.
Nothing here was run against the real host: no SSH, no smoke test, no deploy.
Every behavioural claim below comes from the sandboxed test suite, `actionlint`, `shellcheck`, and `mix ci`.

## Approach

### Build in CI, ship the artifact

Recorded as [ADR-025](../../decisions/ADR-025-build-releases-in-github-actions.md).
A GCP free-tier `e2-micro` has 1 GB of RAM shared with the running BEAM; compiling there competes with the process that is currently taking payments.
The release is therefore built on a GitHub Actions runner with the Elixir 1.18.x / OTP 27 pair `ci.yml` already pins, tarred, and `scp`ed to the VM.
ERTS ships inside the release, so the VM no longer needs Erlang or Elixir at all.

> **Correction (2026-08-24).** This originally read "built on `ubuntu-latest`", and the runner is now pinned to `ubuntu-22.04`.
> The bundled ERTS is linked against the *build* machine's glibc, and glibc is forward-compatible only, so the runner's glibc must be `<=` the target's.
> `ubuntu-latest` rolled to Ubuntu 24.04 (glibc 2.39) while the VM runs Debian 12 (glibc 2.36), and deploy run `32682797726` failed on the VM with `GLIBC_2.38' not found`.
> See [ADR-026](../../decisions/ADR-026-pin-the-deploy-runner-to-the-target-glibc.md) and [OPERATIONS.md → Build Runner And The Target's glibc](../../OPERATIONS.md#build-runner-and-the-targets-glibc).

### Logic in scripts, not in YAML

Inline YAML cannot be unit tested, and the properties that matter here are precisely the ones that need tests.
So the deploy is two bash scripts the workflows call in thin steps:

- `scripts/deploy/remote_deploy.sh` - runs on the VM. Subcommands `activate`, `rollback`, `prune-plan`.
- `scripts/deploy/ssh_deploy.sh` - runs on the runner. Uploads and invokes the above over SSH.

### Testing a deploy without a machine to deploy to

`test/support/deploy_sandbox.ex` builds a throwaway deploy root, fake release tarballs, and `sudo` / `systemctl` / `systemd-run` / `chown` / `ssh` / `scp` stubs that all append to one ordered log.

The trick that makes *ordering* assertable rather than merely "each step happened": every stub records the `current` symlink target at the moment it runs.
So a log line reading

```
migrate id=<new> current=<old>
```

is direct evidence that migrations ran before the swap, and

```
systemctl restart notable.service current=<new>
```

is direct evidence the swap preceded the restart.
No test inspects the script's source; they all drive the real script.

## Design decisions worth recording

### Rollback target selection

The rollback target is **the newest release strictly older than the current one**, not "the newest release that is not current".

The obvious rule ping-pongs: after rolling R3 → R2, "newest that is not current" selects R3 again and rolls forward.
The strictly-older rule walks R3 → R2 → R1 monotonically. Pinned by a test that rolls back twice.

This makes the `<UTC timestamp>-<short sha>` release id format load-bearing rather than cosmetic: reverse lexicographic sort has to equal reverse chronological sort for the rule to be correct.

### Migrations run through `systemd-run`

The alternative - the deploy script sourcing `DEPLOY_ENV_FILE` - would pull live secrets into the deploy process and require the deploy user to read a root-owned secrets file.

Instead the script passes `--property=EnvironmentFile=$DEPLOY_ENV_FILE` to `systemd-run` and lets systemd apply it, exactly as it does for the service.
The secrets never enter the script's process.

The honest cost, written into `docs/OPERATIONS.md` rather than glossed: granting `systemd-run` via sudoers is root-equivalent, so the deploy key is a root credential on that box however the sudoers line is phrased.

### Database guards

The requirement was that pruning can never reach the SQLite file or its `-wal` / `-shm` companions.
Two guarantees hold; mechanism lives in `scripts/deploy/remote_deploy.sh`:

1. Preflight refuses to `activate` or `rollback` when the database or either companion resolves inside `DEPLOY_ROOT`.
2. Pruning refuses any candidate that contains or is contained by the database or its companions, re-checked immediately before the single `rm`.

Retention is bounded, with a floor of 2.
`prune-plan` reports what pruning would do without deleting, and is how tests assert the pruning guard.
A test traps a database inside a release directory and asserts the pruner protects it; another does the same with only the `-wal` companion present.

### Atomic symlink swap across two userlands

`ln -sfn` is not atomic - it unlinks then links.
The atomic idiom is to create a temporary symlink and `rename(2)` it over the target, which needs an explicit "do not follow the destination symlink" flag: GNU spells it `mv -T`, BSD/macOS spells it `mv -h`.
The script tries both and verifies the resulting `readlink`, so it behaves identically on the target's GNU userland (Debian 12) and on the macOS machine the tests run on.

### Automatic rollback on a failed start

Not asked for, but leaving a payments box down after a failed deploy is worse than the added complexity.
If the unit does not become active after the restart, the deploy re-points `current` at the previous release, restarts, and exits non-zero.
It reuses the same swap-and-restart path as manual rollback.

### `workflow_dispatch` only

No `push` trigger on the deploy workflow. `.github/workflows/deploy.yml` carries an in-file comment naming the exact edit that enables deploy-on-merge, and `docs/OPERATIONS.md` documents the same switch.

One caveat is documented rather than silently accepted: CI and Deploy are separate workflows, so a `push`-triggered deploy would start *alongside* `mix ci`, not after it.

## Verification

Everything below was run in this worktree. Nothing was run against the live host.

- `mix ci`: 393 tests, 0 failures; `credo --strict` clean; dialyzer 0 errors; `ex_dna` 0 clones; `reach.check --arch --smells` OK.
- `actionlint` 1.7.12 on `deploy.yml`, `rollback.yml`, `ci.yml`: clean. The binary is not installed on this machine; it was fetched from the upstream release page into a scratch directory for the run and is not vendored into the repo.
- `shellcheck` 0.10.0 on both deploy scripts: clean.
- 58 deploy-specific tests across three files.

What is **not** verified, and cannot be from here:

- That the real VM's layout matches `DEPLOY_ROOT` / `DEPLOY_ENV_FILE` / unit name as configured. Those are repository variables precisely because this side does not know them.
- That the deploy user has the sudoers grants the scripts need.
- That `systemd-run --wait --collect --pipe` behaves as expected on the target's systemd version.
- Any end-to-end run. The first real dispatch is the captain's, after they create the secrets.

## 2026-08-24 - first live dispatch failed on a build/target glibc mismatch

The captain dispatched the first real deploy. It failed, and the failure was in this milestone's work.

**What happened.** Run [`32682797726`](https://github.com/rizafahmi/notable/actions/runs/32682797726) built cleanly, uploaded, unpacked on the VM, and died running migrations:

```
beam.smp: /lib/x86_64-linux-gnu/libm.so.6: version `GLIBC_2.38' not found
beam.smp: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
deploy: error: migration failed for 20260824T022241Z-7ccd241; /opt/notable/current was left untouched
deploy: removing never-activated release 20260824T022241Z-7ccd241
```

**The deploy machinery was not at fault, and the log proves it.** Migrations ran before the symlink swap, so `current` was never repointed, the never-activated release was removed, and the live service was untouched by the failed deploy. The safety ordering this milestone was built around did exactly what it was designed to do. The single defect was the build environment.

**Cause, traced through the job log rather than assumed.**

1. `runs-on: ubuntu-latest` resolved to `Image: ubuntu-24.04`.
2. `erlef/setup-beam` therefore fetched `Installing Erlang/OTP OTP-27.3.4.16 - built on amd64/ubuntu-24.04` - an ERTS linked against Ubuntu 24.04's glibc 2.39.
3. `mix release` bundled that ERTS into the tarball.
4. The VM is Debian 12 (glibc 2.36). glibc is forward-compatible only, so `beam.smp` could not resolve the `GLIBC_2.38` symbols it was built against.

Verified independently of the run log: `packages.debian.org/bookworm/libc6` is `2.36-9+deb12u14`, matching the VM; Ubuntu jammy's `libc6` is `2.35` and noble's is `2.39` from the archive package indexes; the `actions/runner-images` README currently maps `ubuntu-latest` to Ubuntu 24.04 and still offers `ubuntu-22.04`; `builds.hex.pm` publishes the same `OTP-27.3.4.16` built on `ubuntu-22.04`, so the pin does not cost a toolchain version.

**Why the suite did not catch it.** `deploy_workflow_test.exs` asserted `runs-on: ubuntu-latest`. The guard therefore *required* the broken configuration, and it pinned the wrong axis: a specific floating image instead of the property that image had to satisfy. Swapping the literal for `ubuntu-22.04` would have reproduced the same class of bug the next time anything moved.

**Fix.** The runner is pinned to `ubuntu-22.04` (glibc 2.35 <= 2.36), and the guard now asserts the invariant - see [ADR-026](../../decisions/ADR-026-pin-the-deploy-runner-to-the-target-glibc.md) and [OPERATIONS.md → Build Runner And The Target's glibc](../../OPERATIONS.md#build-runner-and-the-targets-glibc). The pin is a maintenance obligation, not a permanent fix: GitHub retires runner images, so this recurs.

**Verification of the fix.** Written test-first against the unfixed workflow. With `runs-on: ubuntu-latest` restored, the new guard fails 3 of 22:

```
1) pins the deploy runner instead of tracking a floating -latest label
   .github/workflows/deploy.yml: runs-on is ubuntu-latest. A floating label silently
   re-targets the build when GitHub moves it; pin an explicit image.
2) builds on a runner whose glibc the deployment target can execute
3) records in-file why the runner is pinned and that the pin will expire
```

With the pin in place, 22 of 22 pass. The guard was also exercised against the two other drift modes it has to catch:

- `runs-on: ubuntu-24.04` (pinned, but too new) → *"ubuntu-24.04 has glibc 2.39, newer than the deployment target's 2.36 (Debian 12). The release would build and upload, then fail to start on the VM."*
- `runs-on: ubuntu-26.04` (pinned, glibc unknown to the test) → fails, demanding a verified glibc value before that image may be used, rather than passing unchecked.

`mix ci` measured at commit `bf564ff` (the fix commit, before the review follow-up below): 466 tests, 0 failures; credo `--strict` clean; dialyzer 0 errors; `ex_dna` 0 clones; architecture policy OK. That figure is **not** the final total for this branch — the review follow-up recorded below added tests after it was taken. The final total is deliberately left unstated here rather than computed: it will be recorded once `mix ci` is actually run, naming the commit it was measured at.

Still not verified from here, and unchanged by this fix: nothing was run against the live host, and no credentials were sought. That a release built on `ubuntu-22.04` actually starts on the VM is a reasoned conclusion from the glibc ordering, not an observation. The next dispatch is the captain's.

One incidental fix: the "digests assets before building the release" assertion searched the workflow's raw text, so it could be satisfied or broken by a comment. It now strips comment lines and asserts the order of the steps that actually run.

**Review follow-up, same day.** Four review findings were taken and fixed:

- The guard modelled runner compatibility as glibc alone. The bundled ERTS also carries the crypto NIF, which links the *runner's* OpenSSL soname, so an image with an older glibc but `libcrypto.so.1.1` (Ubuntu 20.04) would have satisfied the ordering and still failed to start on this VM, which ships `libssl3` and no `libssl1.1`. The runner table is now `@runner_abi`, holding glibc **and** the OpenSSL soname per image, and a second assertion checks the soname against the target's `libcrypto.so.3` the way glibc is checked. An image with no verified entry still fails rather than passing unchecked, on both axes. Today's `ubuntu-22.04` pin satisfies both (glibc 2.35 <= 2.36; `libcrypto.so.3`), so the pin itself is unchanged.
- ADR-026, `docs/OPERATIONS.md`, `docs/DECISIONS.md` and `AGENTS.md` said the version number was "the whole constraint" - the same over-claiming that made ADR-025's bullet wrong. They now state the general rule (no ABI the runner builds against may exceed what the target provides) with glibc and the OpenSSL soname as the instances **checked so far**, and say plainly that the list is what has been checked rather than what exists.
- The "exactly one workflow builds a release" guard globbed `*.yml` only, so a `release.yaml` would have escaped it. It now globs `*.{yml,yaml}`.
- The rollback "does not build anything" assertion ran against raw file text, the hazard `workflow_steps/1` was introduced to remove. It now strips comments too, so extending rollback.yml's prose cannot fail it spuriously.

`ADR-026` was also added to the sequential ADR index in `docs/ARCHITECTURE.md`, which it had been missing from.

The soname assertion is the one new test in this follow-up, so the guard is 23 tests; the "22 of 22" figure recorded above is the count before it.

## Files

| Path | Role |
| --- | --- |
| `.github/workflows/deploy.yml` | Build on the runner, ship, activate. `workflow_dispatch` only. |
| `.github/workflows/rollback.yml` | Dispatchable rollback. Builds nothing. |
| `scripts/deploy/remote_deploy.sh` | On-VM: activate / rollback / prune-plan. |
| `scripts/deploy/ssh_deploy.sh` | On-runner: upload and invoke over SSH. |
| `test/support/deploy_sandbox.ex` | Sandbox filesystem plus stubbed privileged tooling. |
| `test/notable/deploy/remote_deploy_test.exs` | Ordering, rollback selection, retention, database safety. |
| `test/notable/deploy/ssh_deploy_test.exs` | SSH invocation composition, host key verification, key hygiene. |
| `test/notable/deploy/deploy_workflow_test.exs` | Runner ABI invariant, trigger shape, no hardcoded host, CI untouched, docs in sync. |
| `docs/decisions/ADR-025-build-releases-in-github-actions.md` | Build-in-CI and manual-trigger rationale. |
| `docs/decisions/ADR-026-pin-the-deploy-runner-to-the-target-glibc.md` | Why the runner image is pinned, and to what. |
| `docs/OPERATIONS.md` | Automated flow as the primary path; manual retained as fallback. |

## Next steps for the captain

1. Create the four secrets and the repository variables listed in `docs/OPERATIONS.md` under [Required Secrets And Variables](../../OPERATIONS.md#required-secrets-and-variables).
2. Grant the deploy user the sudoers entries in the same document, or set `DEPLOY_SSH_USER` to `root` and leave the default `sudo -n` prefix (which assumes `sudo` is installed on the VM).
3. Dispatch **Actions → Deploy** once and watch it. The first run creates `releases/` and `current` from scratch, so there is no rollback target yet. (Attempted 2026-08-24 as run `32682797726`; it failed on a build/target glibc mismatch, which is fixed above and needs a fresh dispatch to confirm.)
4. Once satisfied, consider adding a required reviewer to the `production` environment, then make the deploy-on-merge edit.
