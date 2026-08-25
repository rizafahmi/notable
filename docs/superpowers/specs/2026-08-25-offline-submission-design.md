# Offline submission for the audience pages

**Date:** 2026-08-25
**Status:** Decided. Piece 2 (service worker shell cache) is built; pieces 1, 3 and 4
are queued as `notable-offline-http-endpoints`, `notable-offline-outbox` and
`notable-offline-banner` and are to be implemented against this document, not
reconstructed from memory.

## The problem, as observed

The captain gave a conference talk on 2026-08-23 and watched the app fail on venue
wifi. Every audience-facing surface is LiveView: `/` (`DonateLive`) and `/questions`
(`QuestionLive`) submit through `phx-submit` over a persistent websocket, and the
router has no POST route for a piece of feedback or a question. On congested wifi
three separate things break:

1. **The page never loads at all.** Someone scans the QR mid-congestion and gets
   nothing. They never reach the form, and this failure is invisible to the captain:
   those people simply never appear in the data.
2. **The submit event has nowhere to go.** It rides a socket that must stay open. It
   is not queued and not retried; it is dropped.
3. **There is no memory.** Whatever was typed dies with the connection.

These are three failures, not one, and they are fixed by three different layers.

## Decisions (made by the captain)

### Approach: offline-first, in three layers

1. **Plain HTTP submission endpoints** - a POST that works with no socket.
2. **A client-side outbox** - submissions are accepted locally and sent later.
3. **A service worker shell cache** - the pages load from cache when the network
   cannot deliver them.

Chosen over:

- **(a) Queueing on the existing websocket.** The socket is the thing that fails.
  Queueing events for it still needs the socket to come back while the tab is open,
  and it leaves failure (1) untouched.
- **(b) HTTP endpoints with progressive enhancement but no queue.** Fixes (2) for
  the moment the user presses the button, but a POST that fails on lossy wifi is
  still a lost submission, and typed text still dies with the tab.

### Scope: feedback and questions only

- **Feedback** (`Notable.Donations.create_feedback/1` - a `Donation` row with
  `status: "sent"`) and **questions** (`Notable.Questions.create_question/1`) are
  in scope. Both are append-only text with no server-side state to reconcile.
- **Not votes.** A queued vote has to handle the same person voting twice offline,
  votes landing out of order, and counts on screen that disagree with the server.
  `toggle_vote/2` is a toggle, so replaying it out of order flips the wrong way.
- **Not tips.** Queueing a payment is a promise about someone's money. The tip path
  stays exactly as it is: online, synchronous, Mayar QRIS per transaction.

### Behaviour on submit: accept locally, send later

Pressing send always succeeds from the user's point of view. **"Tersimpan"**
(saved) renders instantly and involves no network at all. **"Terkirim"** (sent)
renders when the server has acknowledged it. A submission that is saved but not yet
sent stays visible as such; it is never silently dropped and never silently
duplicated.

### CSRF stays on

`protect_from_forgery` stays on the new endpoints. A queued submission carries the
CSRF token minted when the page loaded. That token is fine minutes later but stale
on a return visit (a new session gets a new token), so the flush handles a rejected
token by fetching a fresh one and retrying, rather than by dropping the submission.
The captain explicitly chose this over turning CSRF off for these routes and adding
a rate limiter in its place.

### Architectural principle: submission UI state lives in the client

"Tersimpan" and "Terkirim" are client state, never LiveView assigns. If "tersimpan"
came from the server it could not render when the server is unreachable, which is
precisely when it is needed. LiveView keeps what it is good at: the live question
list, vote counts, and the word cloud. The two responsibilities do not share state.

## Constraints (facts, not choices)

### Background Sync is Chrome-only

iOS Safari has had service workers since 11.3 but has no Background Sync API. On
iOS a queued submission holds until the next time the page is open with a
connection; it does not fly after the tab closes. Product wording must be honest:
"Tersimpan - akan dikirim saat halaman ini dibuka kembali dengan koneksi", not "will
be sent automatically". Where Background Sync exists it is a bonus, not the design.

### Idempotency is a correctness requirement, not polish

A retried POST whose first response was lost creates duplicate feedback. `/cloud`
renders a word once two *distinct* submissions use it (`Notable.WordCloud`), so one
person's accidental duplicate can push a word over the display threshold on its
own. Every submission therefore carries a client-generated id, and the server
treats a second arrival of the same id as the same submission.

### The Jakarta day boundary

The cloud and the question board are scoped to the current WIB day
(`Notable.Wib.wib_date_range/1`, `list_feedback_for_date/1`,
`list_questions_for_date/1`). A submission typed at 23:58 and delivered at 00:04
would land on the wrong day and never appear. The client stamps the submission
time; the server honours it within a bound.

### There is no request-level rate limiting in this app today

The only throttle is `Notable.SubmissionLimiter`, a 10-second per-key cooldown
applied inside the LiveView submit paths (`{:feedback, ip}`, `{:tip, ip}`,
`{:question, visitor_id}`). It is a cooldown against double-taps, not a rate
limiter, and it is not applied to any HTTP route. Rate limiting is not in scope
here; the new endpoints must apply the same cooldown so they are no weaker than
the socket path, and whoever adds real rate limiting later should not assume it
already exists.

## The four pieces

### Piece 1 - HTTP submission endpoints (`notable-offline-http-endpoints`)

Two POST routes in the `:browser` pipeline (session, CSRF, security headers):

- `POST /feedback` -> `Notable.Donations.create_feedback/1`
- `POST /questions` -> `Notable.Questions.create_question/1`

Request body: the same fields the LiveView forms send, plus

- `client_id` - a UUID generated by the client when the submission is saved
  locally. Persisted on the row and unique per table. A second POST with a known
  `client_id` returns the original row's outcome (`200`, same body) and inserts
  nothing.
- `submitted_at` - ISO-8601 UTC from the client clock. The server uses it for the
  row's `inserted_at` **only if** it is within a bound of server time (proposed:
  not more than 24 hours in the past and not in the future by more than clock
  skew, say 5 minutes); otherwise server time is used and the response says so.
  The bound exists because the client clock is untrusted; the field exists because
  of the day boundary above.

Responses are JSON: `201 {"status":"sent","id":...}` on insert, `200` on a replayed
`client_id`, `422` with changeset errors, `429` when `SubmissionLimiter` refuses,
`403` when CSRF fails (Phoenix's default `Plug.CSRFProtection.InvalidCSRFTokenError`
renders as 403 in prod). The `403` is the signal the outbox uses to refresh its
token.

The LiveView pages keep working for anyone with a socket; the endpoints are what
the outbox talks to. Both paths go through the same context functions and the same
`SubmissionLimiter` keys, so a submission is accepted or refused on the same terms
whichever way it arrives.

Tested in Elixir: idempotent replay inserts nothing; `submitted_at` inside the
bound is honoured and outside it is replaced; the cooldown applies; CSRF is
enforced.

### Piece 2 - service worker shell cache (built)

Fixes failure (1). Files:

- `lib/notable_web/service_worker.ex` - decides what is cached. Tested.
- `lib/notable_web/service_worker/sw.js` - the worker. Read at compile time.
- `lib/notable_web/service_worker/kill.js` - the kill switch worker.
- `lib/notable_web/controllers/service_worker_controller.ex` - serves `/sw.js`.
- `assets/js/sw_register.js` - registration, its own esbuild entry, loaded from the
  root layout (`root.html.heex`) after `app.js`.

Strategy:

- **Network-first for the shell documents** `/` and `/questions`, with a 3 s bound:
  if the network has not answered by then and a cached copy exists, the cached copy
  is served and the network request keeps running to refresh the cache. Fresh when
  the network allows; cached when it does not; never hanging on a lossy link.
- **Cache-first for digested static assets.** `mix phx.digest` content-hashes them
  (`name-<md5>.ext`), so they are immutable and safe to serve from cache
  indefinitely. The precache list is generated from the digest manifest the
  endpoint loads (`cache_static_manifest_latest`) - scripts, stylesheets and
  fonts - never a hand-maintained file list.
- **Untouched:** anything under `/admin`, the LiveView socket (`/live`),
  `/webhooks`, `/dev`, `/phoenix`, every non-GET, every cross-origin request, and
  every document other than the two shell pages. For those the browser behaves as
  if no worker existed.

Versioning, the part that bites:

- The cache name is `notable-<stamp>`, where the stamp is a hash of the worker
  source plus the precache list. A build that ships different assets, or a change
  to the worker itself, gets a new cache; a byte-identical rebuild keeps the same
  one and does not churn.
- `activate` deletes every `notable-*` cache that is not the current one.
- `skipWaiting` plus `clients.claim`, so an update takes effect on the next
  navigation rather than after every tab closes. Nothing force-reloads open pages:
  a forced reload could throw away what someone is typing, and LiveView already
  reloads on reconnect when `phx-track-static` assets change.
- Kill switch: `NOTABLE_SERVICE_WORKER=off` in the environment makes `/sw.js`
  serve a worker that deletes every cache and unregisters itself. Per-browser:
  `await notableServiceWorker.uninstall()` in the console. Procedure in
  [OPERATIONS.md](../../OPERATIONS.md#service-worker).
- `/sw.js` is sent with `Cache-Control: no-cache` so a new build or the kill
  switch is picked up on the next navigation instead of after the browser's 24 h
  script cap.

Known limits, deliberately accepted:

- The cached shell document embeds the CSRF token and LiveView session token from
  the load that cached it. Both are what the CSRF decision above is designed for.
- A page that was never visited is not served offline; the browser shows its own
  offline page. The worker does not ship a synthetic offline document.
- Fonts from Google Fonts are cross-origin and are not cached; the page falls back
  to system fonts offline.

`site.webmanifest` was checked against the worker: `start_url: "/"`,
`scope: "/"`, and the 192/512 icons are correct and served, so the site is
installable with a worker in place. Nothing needed correcting. One thing to know:
`display: standalone` means an installed copy has no reload button, so the kill
switch and `skipWaiting` are the only ways a bad worker is replaced there.

### Piece 3 - client outbox (`notable-offline-outbox`)

Fixes failures (2) and (3). Plain JavaScript in `assets/js/`, no framework:

- On submit, the form's fields, a fresh `client_id`, `submitted_at`, and the CSRF
  token from the page are written to **IndexedDB** (`localStorage` is synchronous
  and capped low; IndexedDB is what service workers can also read) and the UI
  shows "Tersimpan". This step touches no network.
- A **flush** runs on submit, on `online`, on page load, and on an interval while
  the page is open. It POSTs each entry to piece 1's endpoint in insertion order,
  one at a time. `201`/`200` -> entry removed, UI shows "Terkirim". `403` -> fetch
  `GET /` (or a dedicated small endpoint) to read a fresh `csrf-token` meta, update
  the stored token, retry once. `422` -> entry removed and shown as rejected with
  the server's reason (it will never succeed). `429` and network errors -> keep the
  entry, back off, try again on the next trigger.
- **Draft persistence**: the form's current text is saved to IndexedDB on input and
  restored on load, so a closed tab does not lose what was typed.
- Where the browser has Background Sync, register a sync tag on save so Chrome can
  flush after the tab closes; the service worker's `sync` handler runs the same
  flush against the same store. iOS gets no such handler and the wording says so.
- Submission state is rendered by this code, not by LiveView. The LiveView form is
  progressively replaced: `phx-submit` is intercepted and the outbox takes over.

Tested in Elixir where the decisions are visible from Elixir (the endpoints, the
token refresh contract); the browser behaviour is verified manually in devtools
offline mode and documented with screenshots, as piece 2 was.

### Piece 4 - offline banner (`notable-offline-banner`)

A small, honest status strip on `/` and `/questions`, driven by `navigator.onLine`
plus the outbox's own success/failure (`onLine` alone is a liar on captive wifi):
"Offline - kiriman disimpan dulu" with the pending count, "Mengirim...", and
"Semua terkirim". Client-side only, same principle as above. It says on iOS that
pending items send when the page is next opened with a connection.

## What is not in this design

- Rate limiting (see the constraint above).
- Votes and tips offline.
- Any change to the display pages `/overlay`, `/qr`, `/qr-overlay`, `/cloud`,
  `/cloud-overlay`, or to `/admin`.
- A JS test runner. Every testable decision is pinned from Elixir; browser
  behaviour is verified by hand and recorded.
