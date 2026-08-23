# Project Progress

## Current State
- `/cloud` (full-screen dark) and `/cloud-overlay` (transparent OBS source) render a live word cloud of **current WIB-day** audience feedback for the closing minutes of a talk. Feedback carries **no moderation state**, so display is gated by two hard rules in `Notable.WordCloud`: a word needs **two distinct submissions**, and a profanity/slur blocklist (`Notable.WordCloud.Lexicon`, exact-token) filters words out. Both are proven absent from rendered output by test. See [Milestone 16 log](milestones/16-feedback-word-cloud/milestone-log.md)
- `/qr` and `/qr-overlay` now render an animated canvas QR (lightning-bolt data modules, colour-coded finders, data-flow wave, pathway pulses, multiply scanner sweep) for [#6](https://github.com/rizafahmi/notable/issues/6). This also fixed three live defects on `main`: both pages rendered a blank QR, and the PNG download was broken by CSP plus a 150px rasterisation. Scannability is enforced by a per-pixel luminance budget in `Notable.Qr` and verified with OpenCV; see [Milestone 15 log](milestones/15-animated-qr-page/milestone-log.md)
- Notable rename slice 3/4 ([#68](https://github.com/rizafahmi/donatex/issues/68)): `NOTABLE_BASE_URL` is canonical; `DONATEX_BASE_URL` remains a temporary alias in runtime/dev config, `.env.example`, and OPERATIONS. Slices 1–2 merged ([#66](https://github.com/rizafahmi/donatex/issues/66) / PR #70, [#67](https://github.com/rizafahmi/donatex/issues/67) / PR #71). Remaining: GitHub rename ([#69](https://github.com/rizafahmi/donatex/issues/69)); parent [#2](https://github.com/rizafahmi/donatex/issues/2).
- Tip → Mayar QRIS path is rate-limited per peer IP via `SubmissionLimiter` (`{:tip, ip}`) before `create_qr` (fixes [#27](https://github.com/rizafahmi/donatex/issues/27)); persist-failure remains fail-closed for the donor; see [Milestone 14 log](milestones/14-tip-rate-limit/milestone-log.md)
- Webhook ops hardening for [#31](https://github.com/rizafahmi/donatex/issues/31) is complete; see [Milestone 13 log](milestones/13-webhook-ops-hardening/milestone-log.md)
- Overlay alert acknowledgement is now persistence-gated: the OBS overlay only clears the current tip alert and advances the queue after `mark_donation_alerted_by_id/1` succeeds; on failure the alert restarts its visible lifecycle, retries persistence, and remains recoverable, fixing [#28](https://github.com/rizafahmi/donatex/issues/28); see [Milestone 13 log](milestones/13-overlay-alert-persistence/milestone-log.md)
- Toast/flash notifications now auto-dismiss after 5 s via a `FlashAutoHide` JS hook on the shared `flash/1` component (fixes [#39](https://github.com/rizafahmi/donatex/issues/39)); per-kind generations reset identical repeated flashes while connection-error toasts stay manual; see [Milestone 12 log](milestones/12-toast-auto-hide/milestone-log.md)
- Donor appreciation opt-in is now a prominent purple selectable CTA titled “Tambah tip untuk mendukung,” with the accurate “Mulai Rp5.000” entry price and a clear selected state; see [Milestone 4 log](file:///Users/riza/code/donatex/docs/milestones/4-optional-appreciation-experience/milestone-log.md)
- Concurrent public-board upvotes no longer crash `QuestionLive`: a lost unique-index race reloads the board while preserving one vote per visitor and normal toggle behavior (fixes [#29](https://github.com/rizafahmi/donatex/issues/29)); see [Milestone 10 log](milestones/10-audience-questions-board/milestone-log.md)
- Milestone 10 (Audience Questions Board): complete — a secondary public Q&A surface at `/questions` lets the audience submit questions (optional name, else `Anonim`) and toggle one anonymous upvote per question; Today is ranked open→answered, votes desc, oldest first; prior WIB dates collapse and load on demand; an authenticated `/admin/questions` page lets the streamer answer/reopen/hide/restore; public and admin views converge in real time via PubSub; raw visitor ids are hashed (never persisted/logged); see [milestone-log](file:///Users/riza/code/donatex/docs/milestones/10-audience-questions-board/milestone-log.md) and [ADR-024](file:///Users/riza/code/donatex/docs/decisions/ADR-024-secondary-public-qa-questions-board.md)
- Milestone 9 (Donor Visitor Presence): complete — anonymous signed-session Presence counts unique browsers, deduplicates tabs, and shows real-time social proof only at 3+ visitors; review follow-up closed durable fail-hidden track/list failures and lifecycle test sync; see [milestone-log](file:///Users/riza/code/donatex/docs/milestones/9-donor-visitor-presence/milestone-log.md)
- Milestone 8 (SEO Optimization): complete — see [milestone-log](file:///Users/riza/code/donatex/docs/milestones/8-seo-optimization/milestone-log.md)
- Milestone 7 (End-to-End Refinement and Release Check): complete — see [milestone-log](file:///Users/riza/code/donatex/docs/milestones/7-end-to-end-refinement-release-check/milestone-log.md)
- Test status for the latest donor CTA change: 31 focused tests, 0 failures; format check and compile warnings-as-errors passed; mobile browser verification passed
- Donor submission now uses one mode-aware button: appreciation off sends free feedback; appreciation on continues through tip validation and QRIS
- Release status: mobile donor and OBS-sized browser smoke checks passed; ready for deployment configuration and a live Mayar transaction smoke check

## Completed
- [x] Audience feedback word cloud at `/cloud` and `/cloud-overlay`, with two display-time safety rules — see [Milestone 16 log](milestones/16-feedback-word-cloud/milestone-log.md).
- [x] [#6](https://github.com/rizafahmi/notable/issues/6) Artistic animated `/qr` page with a decoder-verified scannability budget — see [Milestone 15 log](milestones/15-animated-qr-page/milestone-log.md).
- [x] [#27](https://github.com/rizafahmi/donatex/issues/27) Tip path rate-limit Mayar QR + orphan QRIS fail-closed — see [Milestone 14 log](milestones/14-tip-rate-limit/milestone-log.md).
- [x] [#31](https://github.com/rizafahmi/donatex/issues/31) Webhook ops hardening — see [Milestone 13 log](milestones/13-webhook-ops-hardening/milestone-log.md).
- [x] Replace the decorative `/qr` lightning-dot grid with a scannable EQRCode SVG and SVG-based PNG download
- [x] Donor form → Mayar dynamic QR → local `pending` donation row
- [x] Mayar webhook → DB transition to `paid` (deduped) → PubSub broadcast
- [x] Overlay consumes broadcasts, recovers missed alerts from DB, and plays alerts sequentially
- [x] Admin is basic-auth protected and can replay an alert without mutating `alerted`
- [x] Mayar client resolves a stable transaction id from the QR create response (`transactionId`/`id`) or a unique recent `/transactions/unpaid` lookup, validates QR image URL schemes, and avoids logging usable QR URLs
- [x] Mayar create QR logging indicates whether the transaction id came from response fields or unpaid-transaction lookup (`id_source=response|unpaid`) and whether the QR asset UUID matched the stored transaction id
- [x] Decide and test partial-failure behavior for “QR created but DB insert fails”
- [x] Add safe lifecycle logging (QR creation, webhook accept/reject/duplicate, admin replay)
- [x] Confirm Mayar `POST /qrcode/create` response shape against real traffic (can return only `data.amount` + `data.url`)
- [x] Add `x-content-type-options: nosniff` to shared browser security headers
- [x] Fix donor custom amount browser validation by aligning input `min`/`step` and enforcing server-side multiples-of-1000
- [x] Add feature coverage for webhook correlation when QR create omits transaction id and the real transaction id is resolved from `/transactions/unpaid`
- [x] Fix Credo nesting findings in DonateLive amount validation and Mayar create QR logging helpers
- [x] Stabilize SQLite DB tests by running donations DataCase tests non-async
- [x] Validate donation query indexes (`donations_recovery_queue_idx`, `donations_order_idx`) via migration tests
- [x] Fix live Mayar correlation failure where the QR image UUID differed from the webhook `transactionId` by resolving the real transaction id from `/transactions/unpaid` and failing closed when it cannot be uniquely determined
- [x] Remove the stale QR asset UUID fallback in code so omitted `transactionId`/`id` responses always resolve correlation via `/transactions/unpaid` instead of trusting the QR filename
- [x] Apply custom HTML/CSS alert design from user requirements
- [x] Blend custom overlay design with Notable aesthetic (glassmorphism, accent colors, typography)
- [x] Add high-performance canvas confetti burst synced with the audio to maximize celebratory feel
- [x] Add sound effect playback (`smb_stage_clear.wav`) when overlay alerts appear
- [x] Tune overlay alert timing (~8.5 seconds end-to-end) so the audio cue and exit animation can finish cleanly
- [x] Refresh `/` donor page copy/layout and `/overlay` idle prompt to make donation more inviting
- [x] Polish `/overlay` visual styling, typography, layout, and transitions (smooth 60fps compositor animation, glow borders, flexbox alignment, and zero gradient text)
- [x] Document setup and deployment details (env vars, webhook registration, private webhook URL)
- [x] Run a final end-to-end verification pass (manual smoke test)
- [x] Polish `/admin` dashboard layout, typography, telemetry stats, and real-time PubSub updates (new pending, paid status changes, alerted updates, empty state, donor message display, and semantic color matching)
- [x] Add status filters (all, paid, pending) to `/admin` dashboard with paid as default
- [x] Align the overall color scheme and vibe with the user's livestream overlay (cyan and purple developer-terminal aesthetic, terminal window alert layout on `/overlay`)
- [x] Milestone 2 — Free Notes with Safe Submission: free submit + thank-you, 10s peer-IP cooldown, tip secondary path, admin default `all`, nil-amount display, live insert, no replay for sent
- [x] Milestone 3 — Floating Overlay Reactions: free Notes float emoji-only on `/overlay` (3–4s, simultaneous, no recovery); tip celebrations unchanged
- [x] Milestone 4 — Optional Appreciation Experience: collapsed appreciation toggle; free feedback default; tip QR with back/reset and retryable errors
- [x] M4 tip-path hardening: `<.input>` appreciation checkbox, amount preserve on validate, tip submitter `_tip`, `:tip_submitting` guard, toggle-off + free-with-appreciation tests
- [x] M4 review follow-up (S1–S5): Enter→free product lock, tip appreciation gate, paid-step copy, back-reset tip refute, `donor_hero_headline/0`
- [x] M4 appreciation warnings fix (W1–W8): Pending live-insert filter, sticky tip guard + tests, free step guard, tip preserve merge, atomic feedback rate limiter
- [x] Milestone 5 — Unified Admin Inbox: All/Tips/Feedback filters; card fields (reaction, type, time, status); tip-only replay guard; live free + paid updates; Notes empty state
- [x] Milestone 6 — Notable branding / public route polish (per PRD) & redirect /donate to /
- [x] Refresh admin header/subtitle remaining "donation" wording to "notes and tips"
- [x] Complete corrective Milestone 6 user-visible copy audit across donor validation/errors, admin missing-record messages, shared navigation, and overlay terminal branding
- [x] Milestone 7 — Remove manual-paid bypass so only Mayar confirmation can promote pending tips
- [x] Align free reaction timing to 3–4 seconds and donor message input to the 280-character server limit
- [x] Add Indonesian document metadata, live status announcements, and reduced-motion fallbacks
- [x] Verify mobile free feedback, OBS transparency/layout, restart recovery, auto-dismiss persistence, and paid-tip replay in a real browser
- [x] Run the final 144-test, Credo, Dialyzer, duplication, and architecture quality gate
- [x] Unify free feedback and tip submission behind one mode-aware donor-form button and one `submit_feedback` event
- [x] Milestone 8 — SEO Optimization: robots.txt, canonical links, descriptive page titles, meta descriptions, sitemap.xml, llms.txt, Open Graph/Twitter Card tags, Strict-Transport-Security trust signal header, Organization & FAQPage JSON-LD schemas, and 301 permanent redirect for /donate.
- [x] Visitor Analytics & Conversion Funnel: Track raw page views on `/` dynamically via connected socket, broadcast page views via PubSub, and render real-time conversion rates (Feedback & Tip Conversion) on `/admin` with a premium glassmorphic visual card.
- [x] Milestone 9 — Donor Visitor Presence: Track ephemeral signed browser sessions with Phoenix Presence, deduplicate multiple tabs, and show an exact real-time count only at three or more visitors.
- [x] Milestone 10 — Audience Questions Board: secondary public `/questions` Q&A surface with anonymous upvotes, WIB-grouped ranked board, and authenticated `/admin/questions` moderation (answer/reopen/hide/restore); generalized `SubmissionLimiter`; raw visitor ids hashed and never persisted/logged.
- [x] [#39](https://github.com/rizafahmi/donatex/issues/39) Toast auto-hide — see [Milestone 12 log](milestones/12-toast-auto-hide/milestone-log.md).
- [x] [#28](https://github.com/rizafahmi/donatex/issues/28) Overlay alert persistence — advance queue only after `mark_donation_alerted_by_id/1` succeeds; see [Milestone 13 log](milestones/13-overlay-alert-persistence/milestone-log.md).
- [x] [#30](https://github.com/rizafahmi/donatex/issues/30) Admin LiveView re-auth — `AdminBasicAuth` stamps `admin_authenticated` into the session; `live_session :admin` + `NotableWeb.LiveAdminAuth` `on_mount` rejects mounts without the flag (see [ADR-020](decisions/ADR-020-admin-basic-auth-for-mvp.md)).
- [x] [#32](https://github.com/rizafahmi/donatex/issues/32) Flaky admin/donor ExUnit suite — replace `Process.sleep/1` in admin analytics/filters feature tests with `unwrap` + `render` LiveView sync; set Repo-touching `donate_live_test.exs` to `async: false`.

## In Progress
- [#26](https://github.com/rizafahmi/donatex/issues/26) Harden amount-fallback payment correlation — atomic `claim_pending_by_amount/3` (tx id remap + paid in one transaction); fail-closed on ambiguous multi-pending same-amount; 9 new edge-case tests; see [milestone-log](file:///Users/riza/code/donatex/docs/milestones/11-amount-fallback-hardening/milestone-log.md). PR pending.
- [#24](https://github.com/rizafahmi/donatex/issues/24) Questions WIB/today empty listing — fixed on the same PR by making questions tests calendar-relative to `today_wib()` (hardcoded `2026-07-25` drifted).

## Known Issues
- Mayar’s public webhook docs still do not publish a signature/HMAC verification scheme; MVP relies on an HTTPS callback URL with a non-guessable token until Mayar exposes an official signing mechanism
- Webhook parsing accepts `transactionId` with `id` as a fallback, and accepts `transactionStatus` with `status` as a fallback, until sandbox traffic confirms the final Mayar payload shape
- If Mayar omits `transactionId`/`id` and `/transactions/unpaid` does not return a single fresh same-amount match, Notable now fails closed and does not show the QR rather than risk an uncorrelatable payment
- Cross-node visitor totals depend on healthy production DNS clustering and PubSub; only single-node Presence behavior has been verified locally

## Next Steps
1. Extend `Notable.WordCloud.Lexicon`'s blocklist if a live audience surfaces variants it misses — matching is exact-token, so inflected or misspelled forms pass through.
2. Notable rename remaining slice: GitHub repo rename ([#69](https://github.com/rizafahmi/donatex/issues/69)); close parent [#2](https://github.com/rizafahmi/donatex/issues/2) after that lands. Keep `DONATEX_*` env aliases until the captain says drop them.
3. Merge open hardening PRs still awaiting review (#26 amount-fallback) as they land.
4. Configure the production environment and deploy using the documented release process.
5. Verify production DNS cluster membership and that donor Presence totals propagate across nodes before making cross-node count claims.
6. Run one final low-value live Mayar QRIS transaction against the deployed callback URL.

## References
- [DECISIONS.md](file:///Users/riza/code/donatex/docs/DECISIONS.md)
- [PLAN.md](file:///Users/riza/code/donatex/docs/PLAN.md)
- [ARCHITECTURE.md](file:///Users/riza/code/donatex/docs/ARCHITECTURE.md)
- [PRD.md](file:///Users/riza/code/donatex/docs/PRD.md)
- Milestone 2 log: [docs/milestones/2-free-notes-safe-submission/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/2-free-notes-safe-submission/milestone-log.md)
- Milestone 3 log: [docs/milestones/3-floating-overlay-reactions/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/3-floating-overlay-reactions/milestone-log.md)
- Milestone 4 log: [docs/milestones/4-optional-appreciation-experience/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/4-optional-appreciation-experience/milestone-log.md)
- Milestone 5 log: [docs/milestones/5-unified-admin-inbox/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/5-unified-admin-inbox/milestone-log.md)
- Milestone 6 log: [docs/milestones/6-notable-branding-routing/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/6-notable-branding-routing/milestone-log.md)
- Milestone 7 log: [docs/milestones/7-end-to-end-refinement-release-check/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/7-end-to-end-refinement-release-check/milestone-log.md)
- Milestone 8 log: [docs/milestones/8-seo-optimization/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/8-seo-optimization/milestone-log.md)
- Milestone 9 log: [docs/milestones/9-donor-visitor-presence/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/9-donor-visitor-presence/milestone-log.md)
- Milestone 10 log: [docs/milestones/10-audience-questions-board/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/10-audience-questions-board/milestone-log.md)
- Milestone 12 log: [docs/milestones/12-toast-auto-hide/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/12-toast-auto-hide/milestone-log.md)
- Milestone 13 log: [docs/milestones/13-overlay-alert-persistence/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/13-overlay-alert-persistence/milestone-log.md)
- Milestone 14 log: [docs/milestones/14-tip-rate-limit/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/14-tip-rate-limit/milestone-log.md)
- Milestone 13 log: [docs/milestones/13-webhook-ops-hardening/milestone-log.md](file:///Users/riza/code/donatex/docs/milestones/13-webhook-ops-hardening/milestone-log.md)
- Milestone 15 log: [docs/milestones/15-animated-qr-page/milestone-log.md](milestones/15-animated-qr-page/milestone-log.md)
- Milestone 16 log: [docs/milestones/16-feedback-word-cloud/milestone-log.md](milestones/16-feedback-word-cloud/milestone-log.md)
- ADRs: [docs/decisions](file:///Users/riza/code/donatex/docs/decisions)
