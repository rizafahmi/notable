# Design Decisions

This is a lightweight decision log (what/why/when). For detailed context and alternatives, see the ADRs in [docs/decisions](file:///Users/riza/code/donatex/docs/decisions).

## 2026-07-30: Build Releases In GitHub Actions And Ship The Artifact To The VM (ADR-025)
- Reason: Building on the free-tier VM competes with the live BEAM for 1 GB of RAM; build the release on `ubuntu-latest` and deploy by hand (`workflow_dispatch` only) until the automation has been watched in production.
- Reference: [ADR-025](decisions/ADR-025-build-releases-in-github-actions.md)

## 2026-07-25: Add A Secondary Public Q&A Questions Board (ADR-024)
- Reason: Audience questions and anonymous upvotes are a distinct interaction from donation/feedback; model them as a separate bounded context with its own tables and a secondary `/questions` public route plus an authenticated `/admin/questions` moderation page.
- Reference: [ADR-024](file:///Users/riza/code/donatex/docs/decisions/ADR-024-secondary-public-qa-questions-board.md)

## 2026-07-15: Pivot From Donation-First To Feedback-First With Optional Tips (ADR-023)
- Reason: Donation framing created negative audience sentiment and suppressed engagement. Pivoting to feedback-first with optional tips lowers the participation barrier and removes the "asking for money" stigma.
- Reference: [ADR-023](file:///Users/riza/code/donatex/docs/decisions/ADR-023-pivot-feedback-first-with-optional-tips.md)

## 2026-05-03: Remove Overlay Token Route (ADR-022)
- Reason: This is a single-user system; the overlay no longer needs a token-gated route and should be reachable at `/overlay`.
- Reference: [ADR-022](file:///Users/riza/code/donatex/docs/decisions/ADR-022-remove-overlay-token-route.md)

## 2026-05-03: Superseded - Use A Non-Guessable Token Route For Overlay Access (ADR-021)
- Superseded by: [ADR-022](file:///Users/riza/code/donatex/docs/decisions/ADR-022-remove-overlay-token-route.md)
- Previous reason: Keep the OBS overlay private without introducing an accounts system; preserve the “paste URL into OBS” workflow by gating access with a long random token.
- Reference: [ADR-021](file:///Users/riza/code/donatex/docs/decisions/ADR-021-non-guessable-overlay-token-route.md)

## 2026-05-03: Use Basic Auth For Admin Access In MVP (ADR-020)
- Reason: The admin surface is single-user; Basic Auth is a minimal, low-ops gate that avoids building an accounts system for the MVP.
- Reference: [ADR-020](file:///Users/riza/code/donatex/docs/decisions/ADR-020-admin-basic-auth-for-mvp.md)

## 2026-05-02: Validate Mayar QR Image URLs And Redact QR Data From Logs (ADR-017)
- Reason: Prevent unsafe URL rendering and keep webhook correlation correct by validating QR URL schemes, resolving the Mayar transaction id from response fields or a recent unpaid-transactions lookup, and avoiding QR URL leakage in logs.
- Reference: [ADR-017](file:///Users/riza/code/donatex/docs/decisions/ADR-017-mayar-qr-url-validation-and-log-redaction.md)

## 2026-05-02: Fail Closed When QR Is Created But Donation Persistence Fails (ADR-018)
- Reason: Avoid paid-but-untracked transactions by never showing a QR that cannot be correlated to a persisted donation.
- Reference: [ADR-018](file:///Users/riza/code/donatex/docs/decisions/ADR-018-qr-created-but-donation-persist-fails.md)

## 2026-05-02: Require Paid Status And Amount Match For Webhook Processing (ADR-016)
- Reason: Reduce false-positive paid transitions by validating payment status and correlating webhook amounts with persisted donations.
- Reference: [ADR-016](file:///Users/riza/code/donatex/docs/decisions/ADR-016-webhook-acceptance-criteria.md)

## 2026-05-02: Add CSP Security Headers And Production Origin Checks (ADR-015)
- Reason: Harden all public surfaces against XSS and cross-origin abuse in production deployments.
- Reference: [ADR-015](file:///Users/riza/code/donatex/docs/decisions/ADR-015-security-headers-and-origin-checks.md)

## 2026-05-02: Use Erlang :queue For Overlay Alert FIFO (ADR-014)
- Reason: Use a small, battle-tested FIFO data structure with predictable performance for sequential overlay alerts.
- Reference: [ADR-014](file:///Users/riza/code/donatex/docs/decisions/ADR-014-overlay-queue-uses-erlang-queue.md)

## 2026-05-02: Validate Donor Form Input With Ecto Changesets In LiveView (ADR-013)
- Reason: Reuse Ecto changesets for consistent validation and error rendering across donor interactions.
- Reference: [ADR-013](file:///Users/riza/code/donatex/docs/decisions/ADR-013-donor-form-validation.md)

## 2026-05-02: Add An Index For Donation Ordering Queries (ADR-012)
- Reason: Keep admin listing and time-ordered donation reads fast and predictable on SQLite.
- Reference: [ADR-012](file:///Users/riza/code/donatex/docs/decisions/ADR-012-add-admin-donations-order-index.md)

## 2026-05-02: Use Secure HttpOnly Session Cookies In Production (ADR-011)
- Reason: Reduce session theft risk for admin access by using secure cookie flags in production.
- Reference: [ADR-011](file:///Users/riza/code/donatex/docs/decisions/ADR-011-secure-session-cookies-in-production.md)

## 2026-05-02: Drop Redundant Donation Lookup Index (ADR-010)
- Reason: Avoid unnecessary indexes that increase write cost without improving query plans.
- Reference: [ADR-010](file:///Users/riza/code/donatex/docs/decisions/ADR-010-drop-redundant-donation-index.md)

## 2026-05-02: Add A Composite Index For Overlay Recovery Queries (ADR-009)
- Reason: Make “paid AND alerted = false” recovery queries efficient after overlay restarts.
- Reference: [ADR-009](file:///Users/riza/code/donatex/docs/decisions/ADR-009-donation-recovery-index.md)

## 2026-05-02: Use A Tokenized Callback URL As The Mayar Webhook Authenticity Fallback (ADR-008)
- Reason: Mayar does not publish a signature scheme; use a non-guessable token path as the MVP authenticity control.
- Reference: [ADR-008](file:///Users/riza/code/donatex/docs/decisions/ADR-008-mayar-webhook-authenticity-fallback.md)

## 2026-05-02: Donation Lifecycle Invariants And Idempotent Transitions (ADR-007)
- Reason: Ensure webhook deduplication and state transitions remain correct under retries and out-of-order delivery.
- Reference: [ADR-007](file:///Users/riza/code/donatex/docs/decisions/ADR-007-donation-lifecycle-invariants.md)

## 2026-05-02: Donations Table Schema (ADR-006)
- Reason: Define the minimum durable data needed for donor, webhook, overlay recovery, and admin replay.
- Reference: [ADR-006](file:///Users/riza/code/donatex/docs/decisions/ADR-006-donations-table-schema.md)

## 2026-05-02: Land Placeholder Routes Early (ADR-005)
- Reason: Lock the public surfaces and routing shape early so implementation can iterate without churn.
- Reference: [ADR-005](file:///Users/riza/code/donatex/docs/decisions/ADR-005-placeholder-public-surfaces.md)

## 2026-05-02: Use Env-Driven Runtime Configuration And A Local `.env` Workflow (ADR-004)
- Reason: Keep configuration simple and safe (no secrets in code) while supporting local development and production overrides.
- Reference: [ADR-004](file:///Users/riza/code/donatex/docs/decisions/ADR-004-env-driven-runtime-config.md)

## 2026-05-02: Keep Alert Queue In Overlay LiveView State (ADR-003)
- Reason: Avoid extra processes/brokers for MVP; keep sequencing local to the overlay that renders the alerts.
- Reference: [ADR-003](file:///Users/riza/code/donatex/docs/decisions/ADR-003-overlay-queue-in-liveview.md)

## 2026-05-02: Persist Donations At QR Creation Time (ADR-002)
- Reason: Ensure a durable record exists before waiting for webhook confirmation; enables recovery and mapping.
- Reference: [ADR-002](file:///Users/riza/code/donatex/docs/decisions/ADR-002-persist-pending-donations.md)

## 2026-05-02: Use A Phoenix LiveView Monolith (ADR-001)
- Reason: The MVP surface is small and real-time; a single LiveView app minimizes operational and integration complexity.
- Reference: [ADR-001](file:///Users/riza/code/donatex/docs/decisions/ADR-001-phoenix-liveview-monolith.md)
