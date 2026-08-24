# Notable Architecture

## Purpose

This document describes the Notable architecture and constraints. It is written for LLM agents (and humans) that will implement and extend the system. For decision rationale and alternatives, see the ADRs in [docs/decisions](file:///Users/riza/code/donatex/docs/decisions) and the decision log in [DECISIONS.md](file:///Users/riza/code/donatex/docs/DECISIONS.md).

## System Goal

Notable is a self-hosted livestream donation app for a single streamer. It has three user-facing surfaces:

- A public donor page at `/donate`
- An OBS overlay at `/overlay`
- A private admin page at `/admin`

The system must create one Mayar QRIS payment per donation, persist donation state in SQLite, update donation state from webhook events, and show paid donations as sequential overlay alerts that can be replayed from the admin page.

## Hard Constraints

- Single-user, single-streamer system only
- Phoenix 1.8 + LiveView application
- SQLite is the system of record
- `Req` is the HTTP client for Mayar integration
- Donor flow must work on mobile
- Overlay alerts only appear after payment confirmation
- Alerts must never overlap
- Alerts auto-dismiss after ~8.5 seconds (tuned for the overlay animation/audio)
- Overlay recovery must replay `paid` donations where `alerted = false`
- Webhook handling must persist before broadcast
- Duplicate webhooks must be deduplicated by `mayar_transaction_id`
- Admin auth is basic auth for MVP
- Do not introduce multi-stream, analytics, accounts, extra payment methods, or a separate queue service

## Architecture Summary

- Phoenix LiveView handles all user-facing surfaces
- Ecto + SQLite persist all donation state
- Phoenix PubSub carries internal donation-alert events
- The overlay queue lives inside the overlay LiveView process state
- The database, not process memory, is the durable source of truth
- The donor page creates local `pending` donations before Mayar payment confirmation
- Mayar webhook processing upgrades matching donations to `paid`, then broadcasts alert events
- Overlay recovery reads missed paid-but-unalerted rows from SQLite at mount time
- The web layer applies a strict CSP + security header policy, and production uses LiveView origin checks

## High-Level Topology

```diagram
╭────────────────╮
│ Donor Browser  │
╰──────┬─────────╯
       │ LiveView form submit
       ▼
╭─────────────────────────────╮
│ NotableWeb.DonateLive       │
│ creates pending donation    │
│ requests QR from Mayar      │
╰───────────┬─────────────────╯
            │ Req
            ▼
      ╭──────────────╮
      │ Mayar API    │
      ╰──────┬───────╯
             │ webhook POST
             ▼
╭─────────────────────────────╮
│ Mayar Webhook Controller    │
│ + webhook handler           │
╰───────────┬─────────────────╯
            │ persist then broadcast
            ▼
╭─────────────────────────────╮
│ SQLite / Donations context  │
╰───────────┬─────────────────╯
            │ PubSub
            ▼
╭─────────────────────────────╮
│ NotableWeb.OverlayLive      │
│ in-memory alert queue       │
╰───────────┬─────────────────╯
            │ replay action
            ▼
╭─────────────────────────────╮
│ NotableWeb.AdminLive        │
╰─────────────────────────────╯
```

## Core Design Principles

### Database First

SQLite is the durable source of truth. The overlay queue is transient runtime state only. Any runtime state that matters after restart must be derivable from persisted donation rows.

### Functional Context Boundary

Business operations should sit in explicit context or integration modules, not inside controllers or LiveViews. LiveViews orchestrate UI state and call application boundaries.

### Small Monolith

This app should remain a single Phoenix application. Do not split into services, workers, or brokers without clear evidence that the simple architecture is insufficient.

### Queue In LiveView, Not In A Dedicated Service

The alert queue is an implementation detail of the overlay client. For MVP, it should live in `NotableWeb.OverlayLive` assigns plus timers. Do not add a separate GenServer queue service unless the current approach proves inadequate.

## Proposed Module Map

These modules define the primary application boundaries and are expected to remain stable as the MVP evolves.

### Domain And Persistence

- `Notable.Donations`
  - Application boundary for donation lifecycle
  - Creates pending donations
  - Marks donations paid
  - Marks donations alerted
  - Lists donations for admin
  - Fetches paid/unalerted donations for overlay recovery

- `Notable.Donations.Donation`
  - Ecto schema and changeset
  - Owns validation for fields and status values

### Mayar Integration

- `Notable.Mayar.Client`
  - Wraps `Req`
  - Creates dynamic QRIS transactions
  - Normalizes Mayar success/error responses
  - Rejects responses that omit a transaction id
  - Validates QR image URL schemes before rendering (and avoids logging usable QR URLs)

- `Notable.Mayar.Webhook`
  - Parses webhook payloads
  - Extracts `event`, transaction identifiers, amount, donor fields, and status fields

- `Notable.Mayar.WebhookAuth`
  - Encapsulates whatever authenticity mechanism is confirmed
  - Must remain isolated because the Mayar docs do not clearly document signature verification

### Web Layer

- `NotableWeb.DonateLive`
  - Public donation page
  - Form entry, preset/custom amounts, QR rendering, waiting state, paid state

- `NotableWeb.OverlayLive`
  - Private overlay UI
  - Subscribes to donation alert events
  - Seeds queue from DB on mount
  - Displays one alert at a time
  - Marks alerts as acknowledged in the DB

- `NotableWeb.AdminLive`
  - Basic-auth protected admin page
  - Lists donations and replay action

- `NotableWeb.MayarWebhookController`
  - Receives webhook requests after token auth
  - Parses via `Notable.Mayar.Webhook`, then persists and broadcasts through `Notable.Donations` (DB write before PubSub; dedupe by `mayar_transaction_id`)
  - Keeps Mayar HTTP/auth concerns out of the donations context

- `NotableWeb.Plugs.AdminBasicAuth`
  - Basic auth gate for admin routes; stamps `admin_authenticated` into the session on success

- `NotableWeb.LiveAdminAuth`
  - LiveView `on_mount` gate for the `:admin` `live_session` (plug auth does not run on websocket remount); see [ADR-020](decisions/ADR-020-admin-basic-auth-for-mvp.md)

## Data Model

The core persisted entity is `Donation`.

### Donations Table

Implemented fields:

- `id` - local primary key
- `mayar_transaction_id` - unique Mayar transaction identifier
- `donor_name` - required donor display name
- `amount` - integer IDR amount
- `message` - nullable donor message
- `status` - `pending | paid`
- `alerted` - boolean for overlay acknowledgement state
- `inserted_at`
- `updated_at`

### State Semantics

- `pending`
  - Local record created after donor submits the form and a QR is generated
  - Donation exists, but payment is not yet confirmed

- `paid`
  - Confirmed from Mayar webhook handling
  - Eligible for overlay broadcast and replay

- `alerted = false`
  - Paid donation has not yet completed overlay acknowledgement flow

- `alerted = true`
  - Donation has already been displayed or otherwise acknowledged by the overlay path

## Runtime Components

The current supervisor from [lib/notable/application.ex](file:///Users/riza/code/donatex/lib/notable/application.ex) is already a good base for the target app:

- `NotableWeb.Telemetry`
- `Notable.Repo`
- `Ecto.Migrator`
- `DNSCluster`
- `Phoenix.PubSub`
- `NotableWeb.Endpoint`

No extra OTP process is required for donation queueing in the MVP architecture.

## Routing Model

The current router in [lib/notable_web/router.ex](file:///Users/riza/code/donatex/lib/notable_web/router.ex) should evolve toward this shape:

- Browser routes
  - `/donate`
  - `/overlay`
  - `/admin`

- Webhook route
  - `POST /webhooks/mayar/:token`

Admin sits behind the `:admin` pipeline (`AdminBasicAuth`) plus `live_session :admin` / `LiveAdminAuth` (see [ADR-020](decisions/ADR-020-admin-basic-auth-for-mvp.md)).

## Internal Eventing

Phoenix PubSub is the internal real-time backbone.

### Suggested Event Topics

- `donations:paid`
  - Fired after a donation is marked paid in the DB

- `donations:replay`
  - Fired when admin requests a replay

The exact topic naming can be adjusted, but the event contract should stay simple: enough data for overlay rendering without re-querying on every event, while still allowing DB-backed recovery on reconnect.

## Primary Flows

### Flow 1: Donor Creates QR

```diagram
╭──────────────╮
│ Donor opens  │
│ /donate      │
╰──────┬───────╯
       ▼
╭────────────────────────────╮
│ NotableWeb.DonateLive      │
│ validates form             │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ Notable.Donations          │
│ create pending donation    │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ Notable.Mayar.Client       │
│ POST /qrcode/create        │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ DonateLive renders QR      │
│ and waiting state          │
╰────────────────────────────╯
```

### Flow 2: Payment Confirmation

```diagram
╭──────────────╮
│ Mayar sends  │
│ webhook POST │
╰──────┬───────╯
       ▼
╭────────────────────────────╮
│ MayarWebhookController     │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ WebhookAuth                │
│ accept or reject request   │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ Webhook parser             │
│ extract payment fields     │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ Donations context          │
│ confirm status + amount    │
│ mark donation paid         │
│ dedupe by tx id            │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ PubSub broadcast           │
╰──────┬───────────┬─────────╯
       │           │
       ▼           ▼
╭──────────────╮  ╭──────────────╮
│ OverlayLive  │  │ DonateLive   │
│ enqueue alert│  │ show paid UI │
╰──────────────╯  ╰──────────────╯
```

### Flow 3: Overlay Recovery And Replay

```diagram
╭────────────────────────────╮
│ OverlayLive mounts         │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ Donations query            │
│ status = paid              │
│ alerted = false            │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ Seed in-memory queue       │
│ display one alert          │
│ every ~8.5 seconds         │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ Mark donation alerted      │
╰────────────────────────────╯

╭────────────────────────────╮
│ AdminLive replay click     │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ PubSub replay broadcast    │
╰──────┬─────────────────────╯
       ▼
╭────────────────────────────╮
│ OverlayLive enqueues again │
│ without resetting DB state │
╰────────────────────────────╯
```

## Overlay Queue Design

### Chosen Approach

Queue state lives in `NotableWeb.OverlayLive` assigns.

Suggested assigns:

- `current_alert`
- `queued_alerts`
- `dismiss_timer_ref` or equivalent implicit timer behavior

Suggested behavior:

- On mount, subscribe to PubSub and fetch recovery rows
- If nothing is showing, display the next donation immediately
- If an alert is already visible, append new donations to the queue
- Use `Process.send_after/3` to dismiss after ~8.5 seconds
- On dismissal, persist the displayed donation as alerted; move to the next one only after that write succeeds
- Keep the current alert visible and retry after another lifecycle when acknowledgement persistence fails; see [OPERATIONS.md](OPERATIONS.md#overlay-recovery)

### Explicit Non-Goal

Do not introduce:

- A dedicated GenServer alert queue
- An external broker
- A persistent in-memory queue abstraction separate from the DB and overlay LiveView

That would add system complexity without solving an MVP problem the current design cannot handle.

## Web Security

Notable is expected to be deployed to the public internet, so browser-level protections are treated as part of the MVP baseline:

- Apply a strict CSP and related security headers to all routes.
- Require correct production LiveView origin configuration via env-driven `NOTABLE_BASE_URL` (temporary alias: `DONATEX_BASE_URL`).

Implementation details and rationale are captured in ADR-015.

## Webhook Security Risk

The PRD requires that only valid Mayar webhooks trigger alerts. The published Mayar documentation reviewed for this project documents webhook payloads and management endpoints, but does not document a request signature header, shared secret exchange, or HMAC verification scheme.

For MVP, Notable adopts a fallback trust model instead of assuming undocumented signing exists.

### Required Handling

- Isolate authenticity checks in `Notable.Mayar.WebhookAuth`
- Register an HTTPS callback URL that includes a non-guessable `MAYAR_WEBHOOK_TOKEN`
- Reject requests whose token does not match before any database writes or PubSub broadcast
- Do not spread webhook trust assumptions through controller or business logic
- Keep payload validation and donation correlation checks even after token verification
  - Accept only `transactionStatus == paid` (or equivalent fallback)
  - Require webhook amount to match the persisted donation amount

### Residual Risk

- The URL-secret model is weaker than signed webhooks because it does not prove payload integrity
- If Mayar later documents an official signing mechanism, replace the token fallback in `Notable.Mayar.WebhookAuth`

## Error And Idempotency Model

### Webhook Handling

- Reject malformed or unauthorized webhook requests early
- Ignore or safely no-op duplicate deliveries
- Persist before broadcasting
- Return success for already-processed duplicate events when appropriate to avoid useless retries

### Donor Flow

- Failure to create a Mayar QR should not leave the user in a fake success state
- Pending donation creation and Mayar QR creation should be coordinated carefully to avoid abandoned bad rows
- If a pending row is created before the external QR request fails, recovery or cleanup strategy should be explicit in the implementation

### Overlay Runtime

- Overlay crashes are acceptable if the supervisor restarts the LiveView process
- Lost runtime queue state is acceptable because the DB-backed recovery query reconstructs missed paid alerts

## Configuration Boundaries

Configuration should remain brief, env-driven, and boring.

Expected runtime configuration includes:

- `MAYAR_API_BASE_URL`
- `MAYAR_API_KEY`
- `ADMIN_USERNAME`
- `ADMIN_PASSWORD`
- application base URL or endpoint host values as needed

The architecture assumes `.env` is used for local development convenience, but runtime configuration should still be read through Phoenix/Elixir environment APIs.

## Testing Architecture

The testing strategy should protect behavior at the highest valuable layer without over-testing glue code.

### Must-Have Coverage

- Donations context
  - pending creation
  - paid transition
  - alert acknowledgement
  - recovery query

- Mayar client
  - success response normalization
  - failure normalization

- Webhook path
  - invalid request rejection
  - duplicate handling
  - DB write before broadcast

- Overlay behavior
  - queue ordering
  - no overlap
  - auto-dismiss
  - recovery replay

- Admin replay
  - auth protection
  - replay rebroadcast behavior

### Recommended Testing Levels

- Unit tests for parser and context behavior
- LiveView tests for donor, overlay, and admin interactions
- Controller tests for webhook acceptance/rejection
- Manual end-to-end smoke testing for the full donor-to-overlay flow

## Quality Gates For Agents

Before merging meaningful changes into this architecture, agents should confirm:

- `mix ci` passes (see [CONTRIBUTING.md](../CONTRIBUTING.md) for the local quality gate vs `mix precommit`)
- No architecture change violates hard constraints from the PRD
- New code keeps business logic out of controllers and LiveView templates
- No separate queue service was introduced without explicit justification
- No multi-stream or multi-tenant abstractions were added
- Persistence remains the source of truth for replay/recovery semantics

## Implementation Guidance For Agents

### Do

- Keep module names explicit and domain-focused
- Keep Mayar integration isolated behind a client module
- Keep webhook parsing and authenticity checks separated
- Keep overlay queue logic local to the overlay LiveView
- Prefer the smallest correct change that respects the architecture

### Do Not

- Do not design for multiple streamers
- Do not add user accounts or admin subsystems beyond basic auth
- Do not introduce background job infrastructure for the MVP donation path
- Do not move durable business state into GenServers
- Do not assume undocumented Mayar webhook security behavior is real without verification

## ADR Index

Architecture decisions live under [docs/decisions](file:///Users/riza/code/donatex/docs/decisions).

- [ADR-001: Use A Phoenix LiveView Monolith](file:///Users/riza/code/donatex/docs/decisions/ADR-001-phoenix-liveview-monolith.md)
- [ADR-002: Persist Donations At QR Creation Time](file:///Users/riza/code/donatex/docs/decisions/ADR-002-persist-pending-donations.md)
- [ADR-003: Keep Alert Queue In Overlay LiveView State](file:///Users/riza/code/donatex/docs/decisions/ADR-003-overlay-queue-in-liveview.md)
- [ADR-004: Env-Driven Runtime Config](file:///Users/riza/code/donatex/docs/decisions/ADR-004-env-driven-runtime-config.md)
- [ADR-005: Land Placeholder Routes Early](file:///Users/riza/code/donatex/docs/decisions/ADR-005-placeholder-public-surfaces.md)
- [ADR-006: Donations Table Schema](file:///Users/riza/code/donatex/docs/decisions/ADR-006-donations-table-schema.md)
- [ADR-007: Donation Lifecycle Invariants And Idempotent Transitions](file:///Users/riza/code/donatex/docs/decisions/ADR-007-donation-lifecycle-invariants.md)
- [ADR-008: Use A Tokenized Callback URL As The Mayar Webhook Authenticity Fallback](file:///Users/riza/code/donatex/docs/decisions/ADR-008-mayar-webhook-authenticity-fallback.md)
- [ADR-009: Add A Composite Index For Overlay Recovery Queries](file:///Users/riza/code/donatex/docs/decisions/ADR-009-donation-recovery-index.md)
- [ADR-010: Drop Redundant Donation Lookup Index](file:///Users/riza/code/donatex/docs/decisions/ADR-010-drop-redundant-donation-index.md)
- [ADR-011: Use Secure HttpOnly Session Cookies In Production](file:///Users/riza/code/donatex/docs/decisions/ADR-011-secure-session-cookies-in-production.md)
- [ADR-012: Add An Index For Donation Ordering Queries](file:///Users/riza/code/donatex/docs/decisions/ADR-012-add-admin-donations-order-index.md)
- [ADR-013: Validate Donor Form Input With Ecto Changesets In LiveView](file:///Users/riza/code/donatex/docs/decisions/ADR-013-donor-form-validation.md)
- [ADR-014: Use Erlang :queue For Overlay Alert FIFO](file:///Users/riza/code/donatex/docs/decisions/ADR-014-overlay-queue-uses-erlang-queue.md)
- [ADR-015: Add CSP Security Headers And Production Origin Checks](file:///Users/riza/code/donatex/docs/decisions/ADR-015-security-headers-and-origin-checks.md)
- [ADR-016: Require Paid Status And Amount Match For Webhook Processing](file:///Users/riza/code/donatex/docs/decisions/ADR-016-webhook-acceptance-criteria.md)
- [ADR-017: Validate Mayar QR Image URLs And Redact QR Data From Logs](file:///Users/riza/code/donatex/docs/decisions/ADR-017-mayar-qr-url-validation-and-log-redaction.md)
- [ADR-018: Fail Closed When QR Is Created But Donation Persistence Fails](file:///Users/riza/code/donatex/docs/decisions/ADR-018-qr-created-but-donation-persist-fails.md)
- [ADR-019: Deployment Strategy - GCP Free Tier Releases](file:///Users/riza/code/donatex/docs/decisions/ADR-019-deployment-strategy-gcp-free-tier-releases.md)
- [ADR-020: Use Basic Auth For Admin Access In MVP](file:///Users/riza/code/donatex/docs/decisions/ADR-020-admin-basic-auth-for-mvp.md)
- [ADR-021: Use A Non-Guessable Token Route For Overlay Access](file:///Users/riza/code/donatex/docs/decisions/ADR-021-non-guessable-overlay-token-route.md)
- [ADR-022: Remove Overlay Token Route](file:///Users/riza/code/donatex/docs/decisions/ADR-022-remove-overlay-token-route.md)
- [ADR-023: Pivot From Donation-First To Feedback-First With Optional Tips](decisions/ADR-023-pivot-feedback-first-with-optional-tips.md)
- [ADR-024: Add A Secondary Public Q&A Questions Board](decisions/ADR-024-secondary-public-qa-questions-board.md)
- [ADR-025: Build Releases In GitHub Actions And Ship The Artifact To The VM](decisions/ADR-025-build-releases-in-github-actions.md)
