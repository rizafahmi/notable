# Milestone 18 — Offline submission: spec + service worker shell cache

The captain watched the app fail on venue wifi at a talk on 2026-08-23. This milestone
writes the design for fixing that and builds the first of its four pieces.

- Spec: [docs/superpowers/specs/2026-08-25-offline-submission-design.md](../../superpowers/specs/2026-08-25-offline-submission-design.md)
- Piece built here: **service worker shell cache** — `/` and `/questions` load from cache
  when the network cannot deliver them.
- Queued for later, against the spec: `notable-offline-http-endpoints` (piece 1),
  `notable-offline-outbox` (piece 3), `notable-offline-banner` (piece 4).

## Starting state (found, not assumed)

- Every audience surface is LiveView; `/` and `/questions` submit with `phx-submit`
  over the socket and the router has no POST route for feedback or a question.
- `priv/static/site.webmanifest` existed with `start_url: "/"`, `scope: "/"`,
  `display: standalone` and 192/512 icons that `NotableWeb.BrandAssetsTest` proves are
  served. No service worker existed, so the site was "installable" in name only.
- CSP is `default-src 'self'` with no `worker-src`, so a same-origin `/sw.js` registers
  without a CSP change. Inline `<script>` is forbidden by the CSP and by
  `docs/FRONTEND.md`, so registration cannot be an inline snippet in the layout.
- The deploy workflow computes the release id *after* `mix assets.deploy`, and `_build`
  is cached between CI runs, so a compile-time build stamp (`GITHUB_SHA` captured in a
  module attribute) could silently go stale. The stamp is therefore derived at runtime.
- `Notable.SubmissionLimiter` is a 10 s per-key cooldown inside the LiveView submit
  paths — not request-level rate limiting. The spec says so plainly.

## What was built

| File | Role |
|---|---|
| `lib/notable_web/service_worker.ex` | Decides what is cached; builds the stamp; renders `/sw.js`. Tested. |
| `lib/notable_web/service_worker/sw.js` | The worker. Read at compile time (`@external_resource`). |
| `lib/notable_web/service_worker/kill.js` | Kill-switch worker: purges caches, unregisters itself. |
| `lib/notable_web/controllers/service_worker_controller.ex` + router `:service_worker` pipeline | Serves `/sw.js` with `Cache-Control: no-cache`, no session, security headers. |
| `assets/js/sw_register.js` + esbuild entry in `config/config.exs` | Registration, loaded from `root.html.heex` after `app.js`. `app.js` untouched. |
| `config/runtime.exs` | `NOTABLE_SERVICE_WORKER=off` → kill switch. |
| `docs/OPERATIONS.md` → *Service Worker* | Kill switch procedure, per-browser removal, how to check a deploy was picked up. |

Strategy, as the spec records it: network-first for the two shell documents with a 3 s
bound and cache fallback; cache-first for digested assets (`name-<md5>.ext`); nothing
under `/admin`, `/live`, `/webhooks`, `/dev`, `/phoenix`, no non-GET, no cross-origin,
no other document. Precache list = the `.js`, `.css` and `.woff2` entries of the digest
manifest the endpoint loads (`cache_static_manifest_latest`). Cache name
`notable-<stamp>`, stamp = sha256(worker source + precache list)[0..16]; `activate`
deletes the other `notable-*` caches; `skipWaiting` + `clients.claim`; no forced reload.

`site.webmanifest` was checked against the worker and needed no change: `scope: "/"`
matches the worker scope, `start_url` is a shell page, icons are served. Recorded in the
spec, with the one consequence of `display: standalone` (no reload button in an installed
copy, so the kill switch is the only way out there).

## TDD

Tests were written first and watched fail (24 of 25 failing for "module undefined" /
404 / file missing; the one negative-assertion test that passed on a 404 was tightened
to require a 200 first), then the implementation was written to make them pass.

- `test/notable_web/service_worker_test.exs` — precache is generated from the manifest,
  digested paths only, excludes images/audio/SEO files; shell is exactly `/` and
  `/questions`; `/admin`, `/live`, `/webhooks`, `/dev` are never-cache and nothing under
  `/admin` is in any cacheable set; bounded network timeout; **stamp changes when a
  build ships different assets** and is stable for a byte-identical rebuild; the second
  build's worker contains the second build's asset names and not the first's; the
  worker source has `skipWaiting`, `clients.claim`, `caches.delete`; the kill switch
  unregisters, purges, and has no fetch handler.
- `test/notable_web/controllers/service_worker_controller_test.exs` — `/sw.js` is
  JavaScript, `no-cache`, sets no cookie, keeps security headers, serves the kill switch
  when `:service_worker` is `enabled: false`, enabled by default.
- `test/notable_web/service_worker_registration_test.exs` — the root layout loads
  `/assets/js/sw_register.js` on `/` and `/questions`; esbuild has it as an entry; the
  script registers `/sw.js` and exposes the per-browser uninstall.

## Manual verification (Chrome Canary via `chrome-devtools-axi`, prod build)

Run against `MIX_ENV=prod mix assets.deploy` + `mix phx.server` on `:4010` with a
scratch database, so the digest manifest and `?vsn=d` asset URLs are the real ones.
Screenshots in [screenshots/](screenshots/).

| Check | Evidence |
|---|---|
| Worker registers and controls the page | `getRegistration()` → scope `http://localhost:4010/`, `activated`, `controller: true`, caches `["notable-ff9bbe90b65a11c0"]` |
| Cache holds the shell and the digested assets only | keys: `app-a8dd….css`, `app-9374….js`, `sw_register-be6f….js`, `notable-display-98c1….woff2`, `/`, `/questions` |
| **Offline `/` renders** | devtools *Offline*; page title, `h1` "Kirim Masukan & Pesan", assets all 200 from the worker; only the cross-origin Google Fonts request pends — [03-root-offline.jpg](screenshots/03-root-offline.jpg) |
| **Offline `/questions` renders** | title "Tanya Jawab", `controlled: true`, navigation `transferSize: 0` — [04-questions-offline.jpg](screenshots/04-questions-offline.jpg) |
| **Admin not cached** | offline `/admin` → `chrome-error://chromewebdata/` `ERR_INTERNET_DISCONNECTED`; `/admin` absent from every cache — [05-admin-offline-not-cached.jpg](screenshots/05-admin-offline-not-cached.jpg) |
| **Lossy connection falls back instead of hanging** | Devtools *Slow 3G* answered in 11 ms, i.e. throttling did not reach the worker's own fetch on localhost, so it was not accepted as proof. Instead the server process was frozen (`SIGSTOP`) so requests hang with no response: navigation `responseStart: 3017 ms`, `transferSize: 0`, page rendered from cache — [06-root-hung-server-3s-fallback.jpg](screenshots/06-root-hung-server-3s-fallback.jpg) |
| **A new deploy is picked up** | First attempt appended a comment to `sw_register.js`; `--minify` stripped it, output was byte-identical, digest and stamp unchanged (`ff9bbe90b65a11c0`) — which is the deliberate "identical rebuild does not churn" property, not the test wanted. Second attempt added a statement: digest `be6fe550…` → `eac6cc92…`, stamp → `d57f30b0c6dc2525`. On the **first** navigation after restart the page already referenced the new digest and `caches.keys()` was `["notable-d57f30b0c6dc2525"]` — the old cache gone. Offline afterwards served the new `sw_register-eac6cc92….js` with `transferSize: 0`. Reverting the change and rebuilding restored stamp `ff9bbe90b65a11c0` exactly. |
| **Kill switch** | `NOTABLE_SERVICE_WORKER=off` + restart; `curl /sw.js` shows the kill-switch header; after two navigations `getRegistration()` → none, `controller: false`, `caches: []`. Switching back on and navigating once: worker `activated`, cache recreated. |

Observation for piece 4: offline, LiveView paints its red "We can't find the internet /
Something went wrong — attempting to reconnect" toasts over the perfectly usable cached
form (visible in 03). That is the existing flash behaviour, not something this piece
introduced; the honest offline banner in piece 4 is where it gets addressed.

## Verification commands

- `mix ci` — green on the implementation commit (format, compile `--warnings-as-errors`,
  tests, credo `--strict`, dialyzer, ex_dna, reach). Re-run on the final tree; see the
  PR.
- `mix test test/notable_web/service_worker_test.exs test/notable_web/controllers/service_worker_controller_test.exs test/notable_web/service_worker_registration_test.exs`
  — 25 tests, 0 failures.

## Coordination notes

Two other workers were active in this repo (cloud rendering; display font). This change
touches none of their files: `assets/js/app.js` and `assets/css/app.css` are unmodified;
registration is a new esbuild entry and a new file.

## Next

Pieces 1, 3 and 4 as written in the spec. Piece 1 first — the outbox has nothing to
talk to without the HTTP endpoints.
