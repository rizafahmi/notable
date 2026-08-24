# Operations (Setup & Deployment)

## Overview

Notable is a single-streamer Phoenix LiveView app. Operator-facing surfaces include:

- Donor page: `/donate`
- OBS tip/reaction overlay: `/overlay`
- Feedback word cloud: `/cloud` (projector) and `/cloud-overlay` (OBS)
- Admin page: `/admin`

Payments are created as Mayar dynamic QRIS transactions. Notable creates a local `pending` donation row when the QR is generated, then upgrades it to `paid` when Mayar sends a webhook. The overlay shows paid donations as sequential alerts and recovers missed alerts after restarts by querying `paid AND alerted = false` from SQLite.

## Local Development Setup

1. Copy `.env.example` to `.env`.
2. Fill in at least `MAYAR_API_KEY`.
3. Load the variables into your shell with `source .env`.
4. Run `mix setup` the first time, then `mix phx.server`.

With the default `.env.example` values, the local surfaces are:

- Donor page: `http://localhost:4000/donate`
- Overlay: `http://localhost:4000/overlay`
- Feedback word cloud (projector): `http://localhost:4000/cloud`
- Feedback word cloud (OBS): `http://localhost:4000/cloud-overlay`
- Admin: `http://localhost:4000/admin`
- Webhook callback: `http://localhost:4000/webhooks/mayar/<MAYAR_WEBHOOK_TOKEN>`

## Environment Variables

These values are expected to be provided via environment variables.
In development, the intended workflow is `source .env` before starting the server.
In production, set them in the systemd `EnvironmentFile` on the VM (see [Deployment](#deployment)); do not rely on a checked-in `.env` file, and do not have the deploy overwrite that file.

### Application URLs

- `NOTABLE_BASE_URL` (canonical)
  - Public base URL used to build links and derive LiveView origin checks.
  - Example: `https://donate.example.com`
  - Temporary alias: `DONATEX_BASE_URL` — still accepted if `NOTABLE_BASE_URL` is unset. Prefer `NOTABLE_*`; do not remove the alias until the captain says so.
- `PHX_HOST`
  - Public host used for Phoenix endpoint URL config.
  - Example: `donate.example.com`

### Database (Production)

- `DATABASE_PATH`
  - Absolute SQLite path used in production.
  - Example: `/var/lib/notable/notable.db`
- `POOL_SIZE` (optional)
  - Defaults to `5`.

### Phoenix Runtime

- `SECRET_KEY_BASE`
  - Required in production.
  - Generate with: `mix phx.gen.secret`
- `PORT` (optional)
  - Defaults to `4000`.
- `PHX_SERVER`
  - Set to `true` when running as a server in a release / production environment.
- `DNS_CLUSTER_QUERY` (optional)
  - Only needed when using Phoenix DNS clustering.

### Mayar Integration

- `MAYAR_API_BASE_URL`
  - Sandbox: `https://api.mayar.club/hl/v1`
  - Production: `https://api.mayar.id/hl/v1`
- `MAYAR_API_KEY`
- `MAYAR_WEBHOOK_TOKEN`
  - Non-guessable token embedded in the registered Mayar webhook callback URL.
  - Production enforces a minimum length (20+ characters).

### Overlay & Admin

- `ADMIN_USERNAME`
- `ADMIN_PASSWORD`

## Example Production Env File

If you deploy with `systemd`, a file such as `/etc/notable/notable.env` can hold the release environment:

```bash
PHX_SERVER=true
PORT=4000
PHX_HOST=donate.example.com
NOTABLE_BASE_URL=https://donate.example.com
# Temporary alias still accepted: DONATEX_BASE_URL

SECRET_KEY_BASE=replace_me_with_mix_phx_gen_secret
DATABASE_PATH=/var/lib/notable/notable.db
POOL_SIZE=5

MAYAR_API_BASE_URL=https://api.mayar.id/hl/v1
MAYAR_API_KEY=replace_me
MAYAR_WEBHOOK_TOKEN=replace_me_with_a_long_random_token

ADMIN_USERNAME=admin
ADMIN_PASSWORD=replace_me_with_a_strong_password
```

Keep this file readable only by root and the release user.

## Public URLs (What To Copy Into OBS / Mayar)

Assuming `NOTABLE_BASE_URL=https://donate.example.com`:

- Donor page: `https://donate.example.com/donate`
- Overlay (OBS Browser Source): `https://donate.example.com/overlay`
- Feedback word cloud (projector / screen share): `https://donate.example.com/cloud`
- Feedback word cloud (OBS Browser Source): `https://donate.example.com/cloud-overlay`
- Admin: `https://donate.example.com/admin`
- Mayar webhook callback URL: `https://donate.example.com/webhooks/mayar/<MAYAR_WEBHOOK_TOKEN>`

## Mayar Webhook Setup

Mayar webhook authenticity is currently treated as a URL-secret model (token in the callback path). Mayar’s public docs do not describe a signature/HMAC mechanism.

1. Choose a long random `MAYAR_WEBHOOK_TOKEN`.
2. Register the webhook callback URL containing that token:
   - `https://<your-host>/webhooks/mayar/<MAYAR_WEBHOOK_TOKEN>`
3. Ensure the webhook is configured to deliver `payment.received` events.
4. If Mayar’s webhook UI provides a “test webhook” feature, use it against the same callback URL.
5. Verify the public app URL is reachable over HTTPS before enabling live payments.

If Mayar `POST /qrcode/create` omits `transactionId`/`id`, Notable performs a follow-up `GET /transactions/unpaid` lookup and only shows the QR when it can resolve a single fresh same-amount transaction. This avoids displaying a QR that later cannot be matched to the webhook transaction id.

## Recovery & Retry Semantics

### Webhook retries and duplicates

- Webhook delivery is expected to be at-least-once; duplicates are handled idempotently by `mayar_transaction_id`.
- Notable updates the DB before broadcasting `donations:paid`. A duplicate webhook delivery should not rebroadcast.
- If a webhook arrives for a `mayar_transaction_id` that does not exist locally, Notable logs a warning and does not create a donation row.
- Requests with an invalid webhook token are rejected with `404` before controller logic runs.
- Requests that pass the token check return `200 {"ok":true}` when the payload is processed or intentionally ignored as malformed, duplicate, orphaned, non-paid, or amount-mismatched.
- A failure while marking a donation paid or updating its Mayar transaction ID returns `500 {"ok":false}` so Mayar can retry. Check application logs as well as HTTP status codes when validating webhook wiring.

### Overlay recovery

- The overlay LiveView loads missed alerts on mount by querying `paid AND alerted = false` donations.
- Alerts are displayed sequentially. The current overlay keeps each alert mounted for about 8.5 seconds end-to-end so the 6-second audio cue and exit animation can finish cleanly.
- At the end of that lifecycle, the overlay marks the alert `alerted=true` in SQLite before advancing the queue.
- If that write fails, the same alert starts a fresh visible lifecycle and retries; queued alerts remain blocked, and the application logs an `Overlay alert acknowledgement failed` warning.

### Admin replay

- Admin replay rebroadcasts an overlay event for a selected donation.
- Replay does not mutate `alerted` back to `false`.
- Replay re-enters the overlay queue like any other paid donation broadcast, so it still respects sequential playback.

## Production Notes

- Terminate TLS in front of the app (Mayar webhooks should use HTTPS).
- Keep `/webhooks/mayar/:token` URLs private; treat the token as a secret.
- If you change `NOTABLE_BASE_URL` (or its temporary `DONATEX_BASE_URL` alias), ensure it matches the URL users actually load in browsers (LiveView origin checks use it).

## Deployment

Notable runs on a single Linux VM as a `mix release` supervised by `systemd`, per [ADR-019](decisions/ADR-019-deployment-strategy-gcp-free-tier-releases.md).
The release is built by GitHub Actions and shipped to the VM over SSH, per [ADR-025](decisions/ADR-025-build-releases-in-github-actions.md).

The automated flow below is the primary path.
The [manual fallback](#manual-deployment-fallback) is retained for when GitHub Actions is unavailable.
Mechanism lives in [scripts/deploy/remote_deploy.sh](../scripts/deploy/remote_deploy.sh); this section states intent, inputs, and the guarantees that hold.

### What A Deploy Does

[.github/workflows/deploy.yml](../.github/workflows/deploy.yml) builds the release on a pinned `ubuntu-22.04` runner, then [scripts/deploy/ssh_deploy.sh](../scripts/deploy/ssh_deploy.sh) uploads it and invokes [scripts/deploy/remote_deploy.sh](../scripts/deploy/remote_deploy.sh) on the VM.
The runner image is pinned deliberately and must not be changed to `ubuntu-latest` - see [Build Runner And The Target's glibc](#build-runner-and-the-targets-glibc).

Observable behaviour:

- Migrations run before the `current` symlink swaps to the new release.
- The symlink swap precedes the systemd restart.
- Retention is bounded, with a floor of 2.
- If the unit does not come up after the restart, the deploy rolls itself back.

Those orderings and the database guards below are pinned by tests in [test/notable/deploy/](../test/notable/deploy/).

### Build Runner And The Target's glibc

**The deploy runner is pinned to `ubuntu-22.04` on purpose. Do not change it to `ubuntu-latest`.**

The deployment target of record:

| | |
|---|---|
| OS | Debian GNU/Linux 12 (bookworm) |
| glibc | 2.36 (`ldd (Debian GLIBC 2.36-9+deb12u14) 2.36`) |
| Architecture | x86_64 |

`mix release` bundles ERTS, which is why the VM needs no Erlang or Elixir - but the bundled `beam.smp` is dynamically linked against the **build machine's** glibc, and glibc is forward-compatible only.
A binary built against glibc 2.39 runs on 2.39 and later; it cannot run on 2.36.

**The rule: the deploy runner's glibc must be `<=` the target's glibc, and the runner image must be pinned explicitly, never a floating `-latest` label.**

| Runner image | glibc | Runs on this VM? |
|---|---|---|
| `ubuntu-22.04` | 2.35 | yes - current pin |
| `ubuntu-24.04` (= `ubuntu-latest` today) | 2.39 | **no** |

The distribution name is not the constraint; only the version number is. A Debian target and an Ubuntu runner are fine, provided the numbers order correctly.

#### If a deploy fails with `GLIBC_... not found`

Symptom, at the migration step, after the upload succeeded:

```
beam.smp: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
deploy: error: migration failed; /opt/notable/current was left untouched
```

The site is **not** down from this. Migrations run before the symlink swap, so `current` still points at the previous release and the never-activated one is removed. Nothing needs rolling back.

The cause is a build/target glibc mismatch. Check `runs-on:` in [.github/workflows/deploy.yml](../.github/workflows/deploy.yml) against the table above, and check the runner image the failing run actually used (the job log's "Runner Image" group, and the `erlef/setup-beam` line that names the OTP build - `built on amd64/ubuntu-24.04` means the build's glibc came from 24.04). Re-pin to an image whose glibc is `<=` 2.36 and dispatch again.

#### This pin expires

GitHub retires runner images - `ubuntu-20.04` is already gone from the [actions/runner-images](https://github.com/actions/runner-images) table - and Ubuntu 22.04 leaves standard LTS support in April 2027.
`ubuntu-latest` keeps moving too; Ubuntu 26.04 is already in preview.
When `ubuntu-22.04` goes away, Deploy will fail at build time, before anything reaches the VM. The options then are: pin the newest remaining image whose glibc is still `<=` the VM's, upgrade the VM's Debian release first and then the runner, or build in a container matching the target (`hexpm/elixir:<ver>-erlang-<ver>-debian-bookworm-*`), which removes the runner-image dependency for good.

The rule is asserted in [test/notable/deploy/deploy_workflow_test.exs](../test/notable/deploy/deploy_workflow_test.exs), which fails on a floating label, on an image whose glibc exceeds the target's, and on an image whose glibc it has no verified value for. Rationale: [ADR-026](decisions/ADR-026-pin-the-deploy-runner-to-the-target-glibc.md).

[.github/workflows/rollback.yml](../.github/workflows/rollback.yml) is pinned to the same image for consistency only. It builds nothing and produces no artifact the VM executes, so its glibc never reaches the box.
[.github/workflows/ci.yml](../.github/workflows/ci.yml) may keep floating on `ubuntu-latest`: it runs the quality gate and ships nothing to the VM.

### Triggering A Deploy

Deploys are `workflow_dispatch` only.
Nothing deploys on merge, on a tag, or on a schedule, because the target serves live donors and live payments.

1. Push your change and let [.github/workflows/ci.yml](../.github/workflows/ci.yml) go green on `main`. The deploy workflow does not re-run the quality gate.
2. Open **Actions → Deploy → Run workflow**.
3. Leave `ref` as `main`, or enter a specific branch, tag, or SHA to deploy something else.
4. Watch the run. The final log lines name the release id that went live.

The same thing from the CLI:

```bash
gh workflow run deploy.yml --field ref=main
gh run watch
```

Deploy and rollback share one concurrency group, so two runs can never fight over the `current` symlink.

### Required Secrets And Variables

Create these under **Settings → Secrets and variables → Actions**.
Nothing about the machine is committed to this repository, so a deploy fails fast and loudly until every required entry exists.

Secrets (masked in logs):

| Name | Example | What it is |
| --- | --- | --- |
| `DEPLOY_SSH_HOST` | `34.101.0.7` | Hostname or IP that Actions connects to. |
| `DEPLOY_SSH_USER` | `deployer` | SSH login user on the VM. |
| `DEPLOY_SSH_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----\n…` | Private half of the deploy key, whole file including the trailing newline. |
| `DEPLOY_SSH_KNOWN_HOSTS` | `34.101.0.7 ssh-ed25519 AAAAC3NzaC1…` | Output of `ssh-keyscan <host>`, pinning the VM's host key so the deploy cannot be redirected. |

Variables (visible in logs, and none of them are secret):

| Name | Example | What it is |
| --- | --- | --- |
| `DEPLOY_ROOT` | `/opt/notable` | Release root on the VM. Holds `releases/`, `incoming/`, `bin/`, and the `current` symlink. |
| `DEPLOY_SYSTEMD_UNIT` | `notable.service` | The unit the deploy restarts. |
| `DEPLOY_DATABASE_PATH` | `/var/lib/notable/notable.db` | Where SQLite lives. Must be outside `DEPLOY_ROOT`. |
| `DEPLOY_ENV_FILE` | `/etc/notable/notable.env` | The runtime environment file. Owned by you. The deploy passes its path to systemd and never writes, templates, or replaces it. |
| `DEPLOY_RELEASE_USER` | `notable` | Optional. User the unpacked release is chowned to, and that migrations run as. |
| `DEPLOY_KEEP_RELEASES` | `5` | Optional, default `5`, minimum `2`. How many release directories to retain. |
| `DEPLOY_SSH_PORT` | `22` | Optional, default `22`. |

The workflows also reference a `production` GitHub environment.
It is created automatically on the first run.
Adding a required reviewer to it is the cheapest way to put a human approval in front of every deploy, and it is worth doing before switching to deploy on merge.

### One-Time VM Setup

The deploy creates `releases/`, `incoming/`, `bin/`, and the `current` symlink under `DEPLOY_ROOT`.
`DEPLOY_ROOT` itself, the env file, and the database must already exist:

```
/opt/notable/                     # DEPLOY_ROOT (must pre-exist)
  bin/remote_deploy.sh            # re-uploaded on every run
  incoming/                       # upload staging, cleared after each deploy
  releases/20260730T101500Z-a1b2c3d/
  current -> releases/20260730T101500Z-a1b2c3d
/etc/notable/notable.env          # DEPLOY_ENV_FILE, yours, never written by the deploy
/var/lib/notable/notable.db       # DEPLOY_DATABASE_PATH, outside DEPLOY_ROOT
```

1. Create the deploy user and add the deploy key's public half to its `~/.ssh/authorized_keys`.
2. `sudo mkdir -p /opt/notable && sudo chown deployer /opt/notable`.
3. Create `/etc/notable/notable.env` from the [example env file](#example-production-env-file) and keep it readable only by root and the release user.
4. Create the database directory: `sudo mkdir -p /var/lib/notable && sudo chown notable /var/lib/notable`.
5. Install the systemd unit shown under [systemd (Example)](#systemd-example) and `sudo systemctl enable notable`.
6. Grant the deploy user the privileges below.

The deploy needs to restart the unit, query its state, run migrations through `systemd-run`, chown the unpacked release, and remove old release directories:

```
deployer ALL=(root) NOPASSWD: /usr/bin/systemctl restart notable.service, \
                              /usr/bin/systemctl is-active *, \
                              /usr/bin/systemd-run *, \
                              /usr/bin/chown -R notable /opt/notable/releases/*, \
                              /usr/bin/rm -rf /opt/notable/releases/*
```

Be clear-eyed about what that grants: `systemd-run *` can start a unit as any user with any command, so it is root-equivalent.
The deploy key is therefore a root credential on that box no matter how the sudoers line is written, and it should be treated as one.
If you would rather SSH as root, set `DEPLOY_SSH_USER` to `root` and leave the default `sudo -n` prefix in place.
That path assumes `sudo` is installed on the VM, so a missing `sudo` fails loudly instead of silently changing privilege behaviour.

Migrations run through `systemd-run` so the secrets in `DEPLOY_ENV_FILE` are applied by systemd and never enter the deploy script's own process.
Database location guarantees that do not depend on reading that file are under [The Database Is Never Touched](#the-database-is-never-touched).

### Rolling Back

Rollback is a symlink swap and a restart, driven by [.github/workflows/rollback.yml](../.github/workflows/rollback.yml).
It builds nothing, and every release it can select is already unpacked on the VM, so it completes in seconds.

Run **Actions → Rollback → Run workflow**, or:

```bash
gh workflow run rollback.yml
```

Leaving `release_id` empty selects the newest release strictly older than the one currently live.
Dispatching it again walks one step further back rather than bouncing between the last two releases.
To jump to a specific release, pass its directory name:

```bash
gh workflow run rollback.yml --field release_id=20260729T084500Z-9f8e7d6
```

Rollback deliberately does not run migrations.
Reversing a schema change is a manual decision, not a side effect of moving a symlink, so a rollback across a destructive migration needs you to think about the data first.

A failed deploy rolls itself back: if the unit does not come up after the restart, the deploy re-points `current` at the previous release, restarts, and then exits non-zero.
You do not need to race it.

### Retention And Pruning

Retention is bounded, with a floor of 2 on `DEPLOY_KEEP_RELEASES`.
How candidates are chosen and removed is owned by [scripts/deploy/remote_deploy.sh](../scripts/deploy/remote_deploy.sh).

To see what pruning would do without deleting anything:

```bash
ssh deployer@<host> "DEPLOY_ROOT=/opt/notable \
  DEPLOY_DATABASE_PATH=/var/lib/notable/notable.db \
  bash /opt/notable/bin/remote_deploy.sh prune-plan"
```

### The Database Is Never Touched

The SQLite file lives at `DATABASE_PATH` outside the release directory, and nothing in the deploy path copies, moves, truncates, or deletes it or its `-wal` / `-shm` companions.

Two guarantees hold:

- Preflight refuses to deploy or roll back when the database, or a WAL companion, resolves inside `DEPLOY_ROOT`.
- Pruning refuses any candidate that contains or is contained by the database or its companions, and re-checks that guard immediately before the single `rm`.

Backups remain your responsibility; see [SQLite Notes](#sqlite-notes).

### Switching To Deploy On Merge

The deploy workflow is manual on purpose while the flow is still new.
When you want it to fire on every merge to `main`, add a `push` trigger next to `workflow_dispatch` in [.github/workflows/deploy.yml](../.github/workflows/deploy.yml):

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      ref:
        ...
```

That is the whole edit.
The `ref` input already falls back to `github.ref`, and the release id is derived from `github.sha`, so both triggers behave identically.
Add a required reviewer to the `production` environment first if you want an automatic deploy to still pause for a human.

Note that CI and Deploy are separate workflows, so a `push`-triggered deploy would start alongside `mix ci` rather than after it.
If you make the switch, either gate the deploy job on the CI workflow completing, or accept that a broken `main` can reach the box and rely on the automatic rollback.

### Manual Deployment Fallback

Use this when GitHub Actions is unavailable.
It performs the same steps as the automation, by hand.

Build somewhere that is not the VM (a free-tier box is too small to build an Elixir release reliably):

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.setup
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
release_id="$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short=7 HEAD)"
tar -czf "/tmp/${release_id}.tar.gz" -C _build/prod/rel/notable .
```

Then drive the same script the automation uses, so the ordering and the database guards still apply:

```bash
RELEASE_ID="$release_id" \
RELEASE_ARCHIVE="/tmp/${release_id}.tar.gz" \
DEPLOY_SSH_HOST=<host> \
DEPLOY_SSH_USER=deployer \
DEPLOY_SSH_KEY_FILE=~/.ssh/notable_deploy \
DEPLOY_SSH_KNOWN_HOSTS_FILE=~/.ssh/known_hosts \
DEPLOY_ROOT=/opt/notable \
DEPLOY_SYSTEMD_UNIT=notable.service \
DEPLOY_DATABASE_PATH=/var/lib/notable/notable.db \
DEPLOY_ENV_FILE=/etc/notable/notable.env \
DEPLOY_RELEASE_USER=notable \
  scripts/deploy/ssh_deploy.sh activate
```

These optional settings are `ssh_deploy.sh` / `remote_deploy.sh` knobs only.
They are not GitHub Actions variables, and the workflows do not forward them:

| Name | Default | What it is |
| --- | --- | --- |
| `DEPLOY_PRIVILEGED_CMD` | `sudo -n` | Command prefix for `systemctl`, `systemd-run`, `chown`, and release-directory `rm`. Set only when you need a non-default prefix for a manual run. |
| `DEPLOY_HEALTH_RETRIES` | `15` | How many `systemctl is-active` polls to make after a restart before treating the unit as failed. |
| `DEPLOY_HEALTH_INTERVAL` | `2` | Seconds between those polls. |

Rollback by hand is the same script:

```bash
… scripts/deploy/ssh_deploy.sh rollback
```

If SSH from your machine is also unavailable and you are on the box itself, the raw steps are:

```bash
sudo -u deployer tar -xzf /path/to/release.tar.gz -C /opt/notable/releases/<release-id>
sudo /opt/notable/releases/<release-id>/bin/migrate     # with the env file applied
sudo ln -sfn /opt/notable/releases/<release-id> /opt/notable/current
sudo systemctl restart notable
```

Prefer the script: `ln -sfn` is not atomic, and the manual path has none of the database guards.

### systemd (Example)

This unit matches the layout above.
`WorkingDirectory` and `ExecStart` both point at `current`, so a symlink swap plus a restart is all a deploy needs.

```
[Unit]
Description=notable
After=network.target

[Service]
Type=simple
User=notable
WorkingDirectory=/opt/notable/current
EnvironmentFile=/etc/notable/notable.env
ExecStart=/opt/notable/current/bin/server
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### VM Provisioning Notes

Notable follows the “single server, no Docker” approach in:

- `https://damonvjanis.medium.com/optimizing-for-free-hosting-elixir-deployments-6bfc119a1f44`

It differs from that article in one major way: Notable uses SQLite (a local file) instead of Postgres.
On GCP, use a persistent disk (the default boot disk is already persistent) and set `DATABASE_PATH` to an absolute path on that disk.

1. Provision a free-tier VM and point your domain DNS at the VM's static IP. The current one is Debian 12; whatever it runs, its glibc constrains the build runner - see [Build Runner And The Target's glibc](#build-runner-and-the-targets-glibc).
2. Ensure HTTPS termination exists (Caddy, nginx, or a managed load balancer).
3. Forward ports 80/443 to the Phoenix port (or run Phoenix on 443 directly).
4. Create the deploy user and configure SSH access.
5. Put secrets/env vars on the VM in the env file, readable only by root and the release user.
6. Install the systemd unit and enable it.
7. Back up SQLite regularly (see [SQLite Notes](#sqlite-notes); WAL adds `-wal`/`-shm` companions).

Erlang and Elixir do **not** need to be installed on the VM.
`mix release` bundles ERTS, and the release is built on the CI runner.
That bundled ERTS is what makes the build runner's glibc matter - see [Build Runner And The Target's glibc](#build-runner-and-the-targets-glibc).

## SQLite Notes

- Keep the database file outside the release directory so deploys don’t overwrite it.
- Use an absolute path like `/var/lib/notable/notable.db` and ensure the directory exists and is writable by the app user.
- `Notable.Repo` runs with SQLite WAL, a 5s busy timeout, and IMMEDIATE write transactions (`journal_mode: :wal`, `busy_timeout: 5_000`, `default_transaction_mode: :immediate` in `config/config.exs`, reasserted in `config/dev.exs` and production `config/runtime.exs`) so writers wait on `busy_timeout` under WAL instead of failing on deferred lock upgrade.
- Optional concurrent A/B bench (not in `mix ci`): `mix notable.sqlite_bench` compares production-intent knobs vs a worse baseline on throwaway DBs; CLI flags and examples live in `mix help notable.sqlite_bench`.
- WAL creates companion files next to `DATABASE_PATH` (`*.db-wal`, `*.db-shm`). For a consistent backup of a live database, stop the app briefly, use SQLite’s online backup API / `.backup`, or copy the main file together with any present `-wal`/`-shm` companions from a quiescent moment—do not copy only the main `.db` while writers are active.
