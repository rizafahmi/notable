# AGENTS.md

## Agent Session Harness

Long-running agents resume from repo artifacts, not chat memory.

### Progress model
- [PROGRESS.md](docs/PROGRESS.md) — project-level current state, known issues, next steps, and pointers into milestone folders
- [docs/milestones/](docs/milestones/) — one folder per milestone (`N-slug/`); detailed work lives in that folder’s `milestone-log.md` (example: [5-unified-admin-inbox/milestone-log.md](docs/milestones/5-unified-admin-inbox/milestone-log.md))
- Milestone folders may also contain a `prompt.md` for scope; treat `milestone-log.md` as the durable per-milestone progress record

### Startup workflow
1. `pwd` and confirm repository root
2. Read [PROGRESS.md](docs/PROGRESS.md) for current milestone and next steps
3. Open the active milestone’s `docs/milestones/<N-slug>/milestone-log.md` (and `prompt.md` if present)
4. Skim [PLAN.md](docs/PLAN.md) / [DECISIONS.md](docs/DECISIONS.md) when the milestone needs broader context
5. Inspect recent commits (`git log --oneline -5`) and working tree (`git status --short`)
6. Run `./init.sh` (setup + `mix ci`) before feature work
7. Continue from PROGRESS.md “Next Steps” and the active milestone log

### Working rules
- One milestone (or one slice within it) at a time
- No completion claim without verification evidence
- Keep supporting fixes narrow; do not silently weaken or change verification rules
- Prefer durable updates to the active `milestone-log.md` plus a short rollup in `docs/PROGRESS.md` over chat-only status

### Required artifacts
- [PROGRESS.md](docs/PROGRESS.md) — project rollup and navigation into milestones
- Active milestone log under [docs/milestones/](docs/milestones/) — detailed session/milestone progress
- [PLAN.md](docs/PLAN.md) — plan index / feature orientation when needed
- [`init.sh`](init.sh) — setup + baseline verification (`mix setup`, then `mix ci`)
- Optional: `session-handoff.md` for compact cross-session resume notes

### Definition of done
- Intended behavior implemented
- Verification ran (`./init.sh`, or a documented narrower command when appropriate)
- Evidence recorded in the active `milestone-log.md`, with PROGRESS.md current-state/next-steps kept in sync
- Repo left restartable for the next session

### End-of-session requirements
1. Update the active `docs/milestones/<N-slug>/milestone-log.md`
2. Update [PROGRESS.md](docs/PROGRESS.md) current state, next steps, and milestone pointers
3. Record risks/blockers in PROGRESS.md (and the milestone log when milestone-specific)
4. Leave `./init.sh` runnable
5. Commit a safe coherent state when the user asks for a commit

## Project Overview

Single-user livestream donation system.
Elixir 1.18, Phoenix 1.8, SQLite 3, Tailwind 4

## Quick Start

- Bootstrap + verify: `./init.sh`
- Install only: `mix setup`
- Start: `mix phx.server` or inside IEx REPL with `iex -S mix phx.server`
- Test: `mix test`
- Full local quality gate: `mix ci` (also `mix precommit` for format/credo/dialyzer/test)

## Constraints
- The app is a single-user, single-streamer system, not multi-tenant.
- Primary donation surfaces remain the donor page and tip/reaction OBS overlay (`/overlay`), plus a simple admin page. Additional audience/display routes (`/questions`, `/qr`, `/cloud`, and matching `-overlay` pairs where they exist) are secondary — see Guidelines.
- Donations must be persisted to SQLite.
- The donor flow must use Mayar-generated dynamic QRIS, one per transaction.
- The overlay must show alerts only after payment confirmation.
- Alerts must be queued sequentially, never overlap, and auto-dismiss after 5 seconds.
- The overlay must recover missed alerts by loading paid AND alerted = false donations from storage after restart.
- Webhook handling must write to DB before broadcast.
- Duplicate webhook deliveries must be deduplicated by mayar_transaction_id.
- The admin page must allow manual replay of missed alerts.
- The donor flow must work on mobile.
- The admin auth should stay simple for MVP: basic auth, not a full auth system.
- The overlay route is `/overlay` and intentionally unauthenticated for the single-user MVP.
- Out-of-scope items are hard “not now” constraints for MVP: no viewer accounts, no multi-streamer support, no analytics dashboard, no custom alert themes, no sound effects, no YouTube API integration, no tipping goals, no mobile app.
- HTTP integration should use `Req`, not `HTTPoison`, `Tesla`, or `:httpc`.
- Forms in LiveView must use `to_form/2` and the shared `<.input>` component.
LiveView pages should follow Phoenix 1.8 layout conventions, including wrapping content in `<Layouts.app ...>`.
- For collections in LiveView, the project guidance prefers streams where appropriate.
- Do not design for multiple streamers or per-stream sessions.
- Do not add richer admin/reporting features beyond donation list + replay.
- Do not add extra payment methods beyond QRIS.
- Do not introduce a separate queue service or external broker unless the simple single-node LiveView + PubSub approach proves insufficient.
- App base URL env is `NOTABLE_BASE_URL` (canonical); `DONATEX_BASE_URL` remains a temporary alias until the captain drops it — see [OPERATIONS.md](docs/OPERATIONS.md).

## Guidelines
- LiveView websocket mount/reconnect bypasses the plug pipeline: a plug like `AdminBasicAuth` only guards the initial HTTP request. Any admin LiveView must re-check auth via an `on_mount` callback wrapped in `live_session` (see `NotableWeb.LiveAdminAuth` + the `:admin` `live_session` in the router).
- The `/qr` and `/qr-overlay` QR is decorated but must stay machine-readable. `Notable.Qr` holds the colour/geometry contract and the measured per-pixel luminance budget; the canvas renderer in `assets/js/app.js` reads that palette from a data attribute rather than defining colours of its own. Changing any QR visual means re-running `test/notable/qr_test.exs`, which decodes rendered output with OpenCV (`test/support/qr_decode.py`) - see [Milestone 15 log](docs/milestones/15-animated-qr-page/milestone-log.md) for why the budget is per-pixel rather than per-module-average.
- Deployment lives in `scripts/deploy/` (bash), not in workflow YAML, because the ordering and database guarantees need tests: see `test/notable/deploy/` and the sandbox in `test/support/deploy_sandbox.ex`, which stubs `sudo`/`systemctl`/`systemd-run`/`ssh`/`scp` so a deploy can be rehearsed with no VM. The VM is live and takes real payments; never run these scripts against it from an agent session. Contract and required secrets/variables: [OPERATIONS.md](docs/OPERATIONS.md#deployment); rationale: [ADR-025](docs/decisions/ADR-025-build-releases-in-github-actions.md).
- The deploy workflow's `runs-on` is a correctness constraint, not a preference: `mix release` bundles ERTS linked against the runner's libraries, and the VM is older than `ubuntu-latest`. Never set it to a floating `-latest` label. The rule is that no ABI the runner builds against may exceed what the target provides; glibc and the OpenSSL soname are the axes verified so far, not a closed list. The rule, the target's recorded values, and what to do when the pinned image is retired are in [OPERATIONS.md](docs/OPERATIONS.md#build-runner-and-the-targets-glibc) and [ADR-026](docs/decisions/ADR-026-pin-the-deploy-runner-to-the-target-glibc.md); `test/notable/deploy/deploy_workflow_test.exs` enforces it.
- Release directory names (`<UTC timestamp>-<short sha>`) are load-bearing, not cosmetic: rollback selects the newest release *strictly older* than the current one, so reverse lexicographic sort must equal reverse chronological sort. Changing the id format breaks rollback.
- Audience "feedback" is a `Donation` row with `status: "sent"` (see `Notable.Donations.create_feedback/1`), and it carries **no moderation state** — no hidden/approved/deleted column, and no hide or delete action in `/admin`. The `/cloud` and `/cloud-overlay` word cloud is the only surface that puts that free text in front of a room, so it loads **current WIB day only** via `Donations.list_feedback_for_date` (not unbounded `list_donations(:feedback)`), rolls retained assigns at WIB midnight via the shared `NotableWeb.WibClock` (same precedent as `QuestionLive`), and is gated at display time by two hard rules in `Notable.WordCloud`: a word needs two distinct submissions, and `Notable.WordCloud.Lexicon`'s exact-token blocklist filters profanity out. The day bound and both safety rules are deliberately not options — do not make them configurable or relax them. See [Milestone 16 log](docs/milestones/16-feedback-word-cloud/milestone-log.md).
- The display face (`priv/static/fonts/notable-display.woff2`) is **generated, not downloaded**: rebuild it with `scripts/fonts/build-display-font.sh`, which subsets upstream Fraunces (OFL) and records why that instance was chosen. Never replace it by copying a URL out of Google Fonts' CSS - that is exactly how it shipped as the *Vietnamese* subset, with no `N` in it, for three months without anything failing. A font with the wrong glyphs still loads. `test/notable_web/display_font_test.exs` reads the shipped binary and is the guard; the OFL notice must stay beside the font. See [Milestone 17 log](docs/milestones/17-display-font-fix/milestone-log.md).
- Display pages projected or captured in front of an audience (`/overlay`, `/qr-overlay`, `/cloud`, `/cloud-overlay`) must use `<Layouts.app variant="overlay">`. The `app` variant constrains content to `max-w-5xl` and renders the flash group, which pops a red reconnect banner over a live talk; `overlay` is the bare full-height surface, and a page that wants a dark background paints it itself.
- `/sw.js` is a service worker that caches the `/` and `/questions` shell and the digested assets so those pages load on bad wifi. It is generated per request by `NotableWeb.ServiceWorker` from the `phx.digest` manifest — never a hand-kept file list — and the cache name is stamped from the worker source plus that list, so a build that ships different assets gets a new cache and the old one is deleted on activate. `test/notable_web/service_worker_test.exs` pins what is cached and that the stamp moves between builds; keep `/admin` and `/live` out of it. A bad worker cannot be removed by deleting a file: the kill switch is `NOTABLE_SERVICE_WORKER=off` ([OPERATIONS.md → Service Worker](docs/OPERATIONS.md#service-worker)). Design and the three queued pieces (HTTP endpoints, outbox, banner): [offline submission spec](docs/superpowers/specs/2026-08-25-offline-submission-design.md).
- Use ExAST when code structure matters; prefer it over regex for Elixir code transformations. Example:

```shell
mix ex_ast.search  'IO.inspect(_)'
mix ex_ast.replace 'IO.inspect(expr, _)' 'Logger.debug(inspect(expr))' lib/
mix ex_ast.diff lib/old.ex lib/new.ex
```

## Topic Docs

- [Domain Glossary](CONTEXT.md) (product terms including Brand)
- [Elixir Guideline](docs/elixir-guide.md)
- [Mix Guideline](docs/mix-guide.md)
- [Phoenix v1.8 Guidelines](docs/phoenix-guide.md)
- [Ecto Guideline](docs/ecto-guide.md)
- [Frontend Guideline](docs/FRONTEND.md)
- [Design Guideline](docs/DESIGN.md)
- [Testing Guideline](docs/test-guide.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Plan Index](docs/PLAN.md)
- [Progress](docs/PROGRESS.md) (project rollup)
- [Milestones](docs/milestones/) (per-milestone `milestone-log.md`)
- [Decision Log](docs/DECISIONS.md)
- [Architecture Decisions (ADRs)](docs/decisions)

<!-- usage-rules-start -->
<!-- igniter-start -->
## igniter usage
_A code generation and project patching framework_

# Rules for working with Igniter

## Understanding Igniter

Igniter is a code generation and project patching framework that enables semantic manipulation of Elixir codebases. It provides tools for creating intelligent generators that can both create new files and modify existing ones safely. Igniter works with AST (Abstract Syntax Trees) through Sourceror.Zipper to make precise, context-aware changes to your code.

## Available Modules

### Project-Level Modules (`Igniter.Project.*`)

- **`Igniter.Project.Application`** - Working with Application modules and application configuration
- **`Igniter.Project.Config`** - Modifying Elixir config files (config.exs, runtime.exs, etc.)
- **`Igniter.Project.Deps`** - Managing dependencies declared in mix.exs
- **`Igniter.Project.Formatter`** - Interacting with .formatter.exs files
- **`Igniter.Project.IgniterConfig`** - Managing .igniter.exs configuration files
- **`Igniter.Project.MixProject`** - Updating project configuration in mix.exs
- **`Igniter.Project.Module`** - Creating and managing modules with proper file placement
- **`Igniter.Project.TaskAliases`** - Managing task aliases in mix.exs
- **`Igniter.Project.Test`** - Working with test and test support files

### Code-Level Modules (`Igniter.Code.*`)

- **`Igniter.Code.Common`** - General purpose utilities for working with Sourceror.Zipper
- **`Igniter.Code.Function`** - Working with function definitions and calls
- **`Igniter.Code.Keyword`** - Manipulating keyword lists
- **`Igniter.Code.List`** - Working with lists in AST
- **`Igniter.Code.Map`** - Manipulating maps
- **`Igniter.Code.Module`** - Working with module definitions and usage
- **`Igniter.Code.String`** - Utilities for string literals
- **`Igniter.Code.Tuple`** - Working with tuples

<!-- igniter-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->

## `docs/`

The `docs/` folder contains the initial PRD and per-milestone prompts used to scaffold this codebase during its initial build-out phase. These files are **temporary** — they exist for documentation and guidance only. They are **not** functional: no code, configuration, or runtime logic in this codebase should import, reference, or depend on anything inside `docs/`.

Do not treat `docs/` as long-living documentation for the codebase. The codebase will evolve past the assumptions and decisions captured here. Once the initial milestones are complete, this folder is expected to be deleted.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
