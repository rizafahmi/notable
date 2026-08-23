# Milestone 16 — Audience feedback word cloud

A closing-slide display page: the captain finishes a talk, switches to it, and the room
sees what the audience actually said as one image.

## Starting state (found, not assumed)

Established by reading the schema, the contexts and every public surface — not assumed
from the task description.

**"Feedback" is a `Donation` row with `status: "sent"`.** Created by
`Notable.Donations.create_feedback/1` from `DonateLive`, listed by
`list_donations(:feedback)`, carrying a free-text `message` (max 280) plus `reaction`
and `donor_name`. Questions are a *separate* record (`Notable.Questions.Question`).

**Feedback carries no moderation state whatsoever.** The `donations` table has only
`mayar_transaction_id, donor_name, reaction, amount, message, status, alerted,
timestamps` — no `hidden_at`, `approved`, `flagged`, or soft-delete — and `AdminLive`
handles exactly two events, `set_filter` and `replay`. There is no hide/delete
affordance anywhere.

**Feedback message text had never been public.** `OverlayLive` renders `@current.message`
only for *paid* tip alerts; a `status: "sent"` feedback produces an emoji float and no
text. So no pre-existing app rule cleared free-feedback text for a projector — it had
only ever been visible behind basic auth on `/admin`.

By contrast `Question` *does* have moderation (`hidden_at`, hide/restore in
`/admin/questions`, `list_questions_for_date` excluding hidden by default).

## Decision

This was escalated rather than decided here, because putting unmoderated audience text
on a screen in front of a live room is a product call. The captain chose: **build from
feedback message text, add no moderation state, do not touch the admin screens**, and
instead gate the display with two hard rules.

## The two safety rules

Both live in `Notable.WordCloud`, are enforced on every render, and are **not options** —
no caller can relax them.

1. **A word needs at least two distinct submissions.** One person cannot put a word on
   the wall, however many times they repeat it. Keyed on distinct donation records:
   `visitor_id` exists (`NotableWeb.Plugs.VisitorId`) but is used only for Presence and
   rate limiting and is **never persisted on a donation**, so there is no reliable
   per-visitor identity on stored feedback to key on. Adding one would need a migration
   and a change to the write path, which this milestone's scope excluded.
2. **A profanity/slur blocklist filters words out** (`Notable.WordCloud.Lexicon`).
   Matching is deliberately **exact-token, never substring**: substring matching causes
   the Scunthorpe problem and would silently swallow `assalamualaikum` for containing
   `ass`. There is a test pinning exactly that.

Both rules are proven absent from *rendered output*, not just from the pure function.

## Design notes

**Weight counts distinct submissions, not raw repetitions**, so a single submitter cannot
inflate a word by repeating it — the same property the ≥2 rule depends on.

**Size uses absolute count thresholds (`[2, 3, 5, 8, 13]` → levels 1–5), not a ratio to
the current maximum.** With relative sizing every word on the projector resizes whenever
the busiest word gains a mention. With absolute thresholds a word changes size only when
its own count crosses a threshold.

**Render order is first-appearance order**, so new words append to the end and
already-visible words keep their position when feedback arrives mid-talk. This is why
`build/2` requires messages **oldest-first** and the LiveView reverses the
day-scoped listing (newest-first from the query).

**Load path is the current WIB day, not all-time.** Mount uses
`Donations.list_feedback_for_date(Wib.today_wib())` (same `today_wib` /
`wib_date_range` precedent as questions); PubSub appends only feedback whose
`inserted_at` falls on that day. An unbounded `list_donations(:feedback)` plus
`max_words` let prior-day high-count terms starve tonight's words at count 2 —
wrong for a closing slide of *this* talk. The LiveView day-scope/starvation
test pins that prior-day fillers never occupy the rendered cap.

**Both routes use the layout's `variant="overlay"`.** The initial attempt used
`variant="app"` for the full-screen page; the browser showed why that is wrong — `app`
constrains content to `max-w-5xl` (so it is not full-screen) *and* renders the flash
group, which popped a red "We can't find the internet" banner over the page on
reconnect. `overlay` is the bare display surface, and the page paints its own
`bg-background` for `/cloud` and nothing for `/cloud-overlay`. Tests pin both the
absence of chrome and the absence of a nested `<main>`.

**No new JavaScript dependency.** The cloud is a flex-wrap list of real `<li>` text —
screen-reader reachable and selectable, never a canvas or image. Frequency is carried in
an `sr-only` "disebut N kali" per word, so meaning is never in colour or size alone.

## Verification

- `mix ci` — **exit 0, 377 tests, 0 failures**, credo/dialyzer/ex_dna/arch all clean.
- 23 unit tests on the pure logic: Indonesian and English stopwords, mixed-language
  input, punctuation and URL stripping, pure numbers, single characters, case folding,
  the cap, deterministic tie-breaking, the empty case, both safety rules, and layout
  stability.
- LiveView tests: both surfaces, empty state, live broadcast, chrome hygiene,
  single-submission and blocklisted words absent from rendered output, and
  previous-WIB-day words cannot fill `max_words` and starve a same-day word.
- Browser-verified end to end at 1920×1080: two feedbacks submitted through the real
  donor form pushed the open `/cloud` page from 23 to 25 words **without a reload**, with
  `sesi` and `inspiratif` appended at the end and the first 23 words unchanged in order —
  the stability guarantee observed live, not just asserted. `/cloud-overlay` computed
  `rgba(0, 0, 0, 0)` on the section, `body` and `html`, so it keys correctly in OBS.

## Notes for the next session

- Dev-DB feedback rows were cleared while capturing the empty state; the dev DB in this
  worktree is throwaway seed data.
- The blocklist is a starting list, not exhaustive. It is exact-token, so inflected or
  deliberately misspelled variants pass. Extend `Notable.WordCloud.Lexicon` as needed;
  `blocklist_size/0` has a test asserting the list has not been accidentally emptied.
