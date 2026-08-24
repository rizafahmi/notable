# ADR-025: Build Releases In GitHub Actions And Ship The Artifact To The VM

## Status

Accepted

## Date

2026-07-30

## Context

[ADR-019](ADR-019-deployment-strategy-gcp-free-tier-releases.md) settled where Notable runs: a single Linux VM, `mix release`, `systemd`, a `current` symlink for fast rollback, SQLite as a file at `DATABASE_PATH`, and no containers.
It did not settle *where the release is built* or *what triggers a deploy*, and until now the answer to both was "a human, by hand, on the box".

The app is live and takes real payments, so the deployment path needed to become repeatable without becoming autonomous.

Two questions had to be answered to automate it.

**Where does the release get built?**
`docs/OPERATIONS.md` previously told operators to run `MIX_ENV=prod mix release` from the app directory on the VM.
That requires Erlang and Elixir installed on a free-tier instance, and it puts a compile - the most memory-hungry thing that will ever happen on that machine - on the same box that is currently serving donors.
A GCP free-tier `e2-micro` has 1 GB of RAM shared with the running BEAM, `esbuild`, and `tailwind`.
Building there is unreliable at best, and when it fails it can take the live service down with it.

**What triggers a deploy?**
Deploy-on-merge is the usual default, but the target takes live payments and the flow has never run before.

## Decision

Build the release on an `ubuntu-latest` GitHub Actions runner and transfer the built artifact to the VM over SSH.

- `MIX_ENV=prod mix assets.deploy` then `MIX_ENV=prod mix release`, on the same Elixir and OTP versions `.github/workflows/ci.yml` already pins.
- The result is tarred, uploaded as a workflow artifact for 14 days, and `scp`ed to the VM.
- Erlang and Elixir are no longer required on the VM at all: `mix release` bundles ERTS.
- The build runner's OS and architecture must be compatible with the VM's (`ubuntu-latest` x86_64 targeting a same-or-newer Ubuntu x86_64 VM).
  An arm64 VM or a VM older than the runner image needs either a matching runner or `include_erts` set to false with Erlang installed on the box.

Deploys are `workflow_dispatch` only, not automatic on merge.

- The captain wants to watch the automation work several times before letting a merge reach a box that takes payments.
- `.github/workflows/deploy.yml` carries an in-file comment naming the exact edit that later enables deploy-on-merge, and `docs/OPERATIONS.md` documents the same switch along with its caveat that CI and Deploy are separate workflows.

The deploy logic lives in `scripts/deploy/remote_deploy.sh` and `scripts/deploy/ssh_deploy.sh`, not in workflow YAML.

- Inline YAML cannot be unit tested, and the properties that matter here - migrate before symlink swap, swap before restart, rollback target selection, and above all that pruning can never reach the database - are exactly the properties that need tests.
- Those tests live in `test/notable/deploy/` and run inside `mix ci` against a sandboxed filesystem with `sudo`, `systemctl`, and `systemd-run` stubbed.

Migrations run through `systemd-run` with `--property=EnvironmentFile=$DEPLOY_ENV_FILE`.

- systemd applies the environment file exactly as it does for the service, so migrations see the same configuration the app will.
- The secrets in that file never enter the deploy script's process.

Observable deploy behaviour (mechanism in `scripts/deploy/remote_deploy.sh`):

- Migrations run before the symlink swap; the swap precedes the restart.
- Bare rollback selects the newest release strictly older than the one live.
- Retention is bounded, with a floor of 2.
- Preflight refuses to activate or roll back when the database or a WAL companion resolves inside `DEPLOY_ROOT`.
- Pruning refuses any candidate that contains or is contained by the database or its companions, re-checked immediately before the single `rm`.
- `prune-plan` reports what pruning would do without deleting.

## Alternatives Considered

### Keep building on the VM

- Pros: no artifact transfer, no SSH credentials in GitHub, one fewer moving part.
- Cons: needs a full Elixir toolchain on a 1 GB instance, competes for memory with the live service, and the build is the least predictable step in the whole flow.
- Rejected: the failure mode is "the box that takes payments runs out of memory", which is the one outcome the automation exists to avoid.

### Deploy automatically on merge to `main`

- Pros: the conventional flow, shortest path from merge to production.
- Cons: the target takes live payments and nobody has watched this automation run yet.
- Rejected for now, deliberately reversible: the enabling edit is documented in the workflow and in the operations doc, and a required reviewer on the `production` environment is the recommended companion change.

### Put the deploy steps directly in the workflow YAML

- Pros: everything visible in one file, no indirection.
- Cons: untestable. The ordering guarantees and the database guards would then be asserted by nothing.
- Rejected: this is the part of the system that can destroy irreplaceable data, so it is the part that most needs tests.

### A deployment tool (`mix_deploy`, Ansible, Kamal, …)

- Pros: less bespoke shell.
- Cons: another dependency to keep current for one VM, and none of them model "never let pruning near the SQLite file" without custom work anyway.
- Rejected for a single-node MVP.

## Consequences

- The repository now needs SSH credentials as GitHub secrets, and the deploy key is effectively a root credential on the VM. `docs/OPERATIONS.md` says so plainly rather than implying the sudoers line contains it.
- The VM no longer needs Erlang or Elixir installed. Existing installs can be left alone; they are simply unused by the deploy.
- Release directory names must sort chronologically, because rollback selects the newest release strictly older than the current one. The `<UTC timestamp>-<short sha>` format is therefore load-bearing, not cosmetic.
- Deploy and rollback share a concurrency group, so a rollback cannot overlap a deploy that is still moving the same symlink.
- The manual checklist in `docs/OPERATIONS.md` is retained as an explicit fallback for when Actions is unavailable, and it drives the same scripts so the guards still apply.
- ADR-019 is unchanged and still governs the runtime shape. This ADR only records where the build happens and how the deploy is triggered.
