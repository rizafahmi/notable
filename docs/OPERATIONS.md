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

These values are expected to be provided via environment variables. In development, the intended workflow is `source .env` before starting the server. In production, set these variables in your process manager / container environment (do not rely on `.env` files).

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

Keep this file readable only by root (or the app user if your process manager requires it).

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

## GCP Free Tier Deployment (Single VM)

This project can be deployed following the “single server, no Docker” approach in:

- `https://damonvjanis.medium.com/optimizing-for-free-hosting-elixir-deployments-6bfc119a1f44`

Notable differs from the article’s example in one major way: Notable uses SQLite (a local file) instead of Postgres. On GCP, use a persistent disk (the default boot disk is already persistent) and set `DATABASE_PATH` to an absolute path on that disk.

### High-level Checklist

1. Provision a free-tier VM (Ubuntu) and point your domain DNS at the VM’s static IP.
2. Install Erlang/Elixir for the versions used by this repo.
3. Ensure HTTPS termination exists (Caddy, nginx, or a managed load balancer).
4. Forward ports 80/443 to the Phoenix port (or run Phoenix on 443 directly).
5. Create a deploy user + configure SSH access.
6. Put secrets/env vars on the VM (systemd drop-in, env file readable only by root, or equivalent).
7. Build and run a release, then manage it via systemd.
8. Back up SQLite regularly (see [SQLite Notes](#sqlite-notes); WAL adds `-wal`/`-shm` companions).

### Release Commands

From the app directory on the VM:

- Build assets: `MIX_ENV=prod mix assets.deploy`
- Build release: `MIX_ENV=prod mix release`
- Run migrations: `_build/prod/rel/notable/bin/migrate`
- Start server: `_build/prod/rel/notable/bin/server`

### systemd (Example)

If you follow the article’s “release directory + current symlink” layout (e.g. `/opt/notable/current`), a minimal systemd unit can run the release `server` script:

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

### SQLite Notes

- Keep the database file outside the release directory so deploys don’t overwrite it.
- Use an absolute path like `/var/lib/notable/notable.db` and ensure the directory exists and is writable by the app user.
- `Notable.Repo` runs with SQLite WAL, a 5s busy timeout, and IMMEDIATE write transactions (`journal_mode: :wal`, `busy_timeout: 5_000`, `default_transaction_mode: :immediate` in `config/config.exs`, reasserted in `config/dev.exs` and production `config/runtime.exs`) so writers wait on `busy_timeout` under WAL instead of failing on deferred lock upgrade.
- Optional concurrent A/B bench (not in `mix ci`): `mix notable.sqlite_bench` compares production-intent knobs vs a worse baseline on throwaway DBs; CLI flags and examples live in `mix help notable.sqlite_bench`.
- WAL creates companion files next to `DATABASE_PATH` (`*.db-wal`, `*.db-shm`). For a consistent backup of a live database, stop the app briefly, use SQLite’s online backup API / `.backup`, or copy the main file together with any present `-wal`/`-shm` companions from a quiescent moment—do not copy only the main `.db` while writers are active.
