# Notable

Self-hosted livestream donation app for a single streamer:

- Donor page (`/donate`) generates a Mayar dynamic QRIS per donation
- OBS overlay (`/overlay`) shows paid donations as sequential on-stream alerts
- Feedback word cloud (`/cloud`, `/cloud-overlay`) for projector or OBS closing slides
- Admin page (`/admin`) lists donations and lets you replay missed alerts

Donations are persisted to SQLite. Alerts only appear after payment confirmation via Mayar webhooks.

## Quick start (local dev)
- Install deps & setup: `mix setup`
- Create env file: `cp .env.example .env`
- Fill in at least: `MAYAR_API_KEY`
- Load env into your shell: `source .env`
- Run: `mix phx.server`
- Open: `http://localhost:4000/donate`

Local URLs (default):
- Donor page: `http://localhost:4000/donate`
- Overlay (OBS browser source): `http://localhost:4000/overlay`
- Feedback word cloud (projector): `http://localhost:4000/cloud`
- Feedback word cloud (OBS): `http://localhost:4000/cloud-overlay`
- Admin: `http://localhost:4000/admin`
- Webhook callback: `http://localhost:4000/webhooks/mayar/<MAYAR_WEBHOOK_TOKEN>`

## Configuration
Notable is configured via environment variables. For the full list (including production-only variables and examples), see [OPERATIONS.md](docs/OPERATIONS.md).

Common variables:
- `MAYAR_API_BASE_URL` (sandbox/prod)
- `MAYAR_API_KEY`
- `MAYAR_WEBHOOK_TOKEN`
- `ADMIN_USERNAME`, `ADMIN_PASSWORD`
- `NOTABLE_BASE_URL` (important in production for LiveView origin checks; temporary alias: `DONATEX_BASE_URL`)

## Mayar webhook authenticity (MVP)
Mayar’s public webhook docs reviewed for this project do not document a signature/HMAC verification mechanism. For MVP, Notable uses a URL-secret model:

- You register a webhook callback URL that includes a long random `MAYAR_WEBHOOK_TOKEN`
- Notable rejects requests whose token does not match before any DB writes or broadcasts

This is weaker than signed webhooks because it does not provide message integrity. If Mayar adds request signing docs later, this project should switch to that mechanism.

## Deployment & ops
[OPERATIONS.md](docs/OPERATIONS.md) covers:
- Mayar webhook callback URL format and registration steps
- URLs to copy into OBS / your browser
- webhook retry/deduping behavior
- overlay recovery behavior (`paid AND alerted = false`)
- production env vars (`DATABASE_PATH`, `SECRET_KEY_BASE`, `PHX_HOST`, etc.)
- the automated deploy: triggering it, the secrets and variables it needs, and how to roll back

Deploys run from GitHub Actions and are triggered by hand (**Actions → Deploy → Run workflow**); nothing deploys on merge.
Rollback is a separate dispatchable workflow that re-points the release symlink and restarts.

## Docs (for contributors)
- Product: [PRD.md](docs/PRD.md)
- Architecture: [ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Decisions: [DECISIONS.md](docs/DECISIONS.md) and [docs/decisions](docs/decisions)

## Contributing
PRs are welcome. New contributors: start with [CONTRIBUTING.md](CONTRIBUTING.md) for setup, local verification (`mix ci`), and PR expectations.

## Security
Please report security issues privately. See [SECURITY.md](SECURITY.md).

## License
MIT. See [LICENSE](LICENSE).

---

## Bahasa Indonesia (ringkas)
Notable adalah aplikasi donasi livestream yang bisa di-host sendiri untuk 1 streamer:

- Halaman donatur (`/donate`) membuat QRIS dinamis via Mayar untuk setiap donasi
- Overlay OBS (`/overlay`) menampilkan alert setelah pembayaran terkonfirmasi (via webhook)
- Awan kata feedback (`/cloud`, `/cloud-overlay`) untuk proyektor atau sumber browser OBS
- Halaman admin (`/admin`) untuk melihat daftar donasi dan replay alert

Panduan setup & deployment: [OPERATIONS.md](docs/OPERATIONS.md).
