# Milestone 17 — `/cloud` as a true packed word cloud

`/cloud` and `/cloud-overlay` rendered their words as a centred `flex-wrap` list: shared
baselines, uniform gutters, one colour, one size. The captain asked for a real word
cloud — clearly different sizes, colours that vary independently of size, words nested
into each other's gaps, some vertical, forming a rough elliptical mass — over a
styling-only pass, knowing it needs JavaScript.

## Starting state

- `Notable.WordCloud.build/2` returned `%{word:, count:, level: 1..5}` in first-appearance
  order. `@min_submissions 2`, `@level_thresholds [2, 3, 5, 8, 13]`.
- `NotableWeb.FeedbackCloudLive` rendered `size_class(level)` and `tone_class(level)`.

### Two defects, not just a layout problem

1. **Colour was a function of frequency.** `tone_class/1` was `rem(level, 3)`, so equal
   counts always produced an identical colour. In a small room *every* qualifying word
   sits at exactly the minimum count of 2, so the whole cloud rendered in one colour at
   one size.
2. **Equal counts were visually identical.** Size came from absolute count thresholds —
   which is deliberate and stays (`Notable.WordCloud`'s moduledoc explains why: a word
   must only resize when *its own* count crosses a threshold, so words do not jump size
   as others gain mentions mid-talk) — but there was no variation *within* a level.

## Where the logic lives

There is no JavaScript test runner in this project and none was added, so the split is:

| Decision | Where | Tested by |
|---|---|---|
| size level (from count) | `Notable.WordCloud` | `test/notable/word_cloud_test.exs` |
| size variation within a level | `Notable.WordCloud.Style` | `test/notable/word_cloud/style_test.exs` |
| colour | `Notable.WordCloud.Style` | same |
| rotation | `Notable.WordCloud.Style` | same |
| contrast between neighbours (tone family, orientation) | `Notable.WordCloud.Style.decorate_all/1` | same |
| **placement only** | `Hooks.WordCloud` in `assets/js/app.js` | verified in a real browser (below) |

`Notable.WordCloud.Style` derives everything from a local **FNV-1a** hash of the word,
salted per aspect (`"tone:"`, `"size:"`, `"spin:"`) so tone, size and rotation are
independent — a single hash would have made every rotated word share a colour. FNV-1a
rather than `:erlang.phash2/1` so the mapping is fixed by this module, not by the runtime.
The hash is the word's *own* choice; the neighbour rules below may overrule it (see
"Second round").

The size bands are provably disjoint: `base_font_size(n) * high < base_font_size(n + 1) * low`
is asserted for every level, so a more-mentioned word is still always the visibly bigger
one even with the within-level variation applied.

## The layout hook

`Hooks.WordCloud` measures each rendered `<li>` (`offsetWidth`/`offsetHeight`, which are
layout sizes and so unaffected by the fit transform) and packs it with a ring-by-ring
spiral search plus rectangle-overlap collision, largest word first. The spiral is
stretched horizontally (`CLOUD_ASPECT`), which is what makes the mass elliptical.
~150 lines, written directly rather than vendored; no npm, no new dependency.

Two mechanics are load-bearing rather than stylistic, and both exist for the same reason —
**LiveView's DOM patch removes attributes the server template does not own**
(`morphdom`'s `morphAttrs` via `dom_patch.ts`), so anything JavaScript writes onto a
patched element is wiped the next time a word arrives:

1. Positions are written into a `<style>` element in `<head>`, keyed by
   `[data-word="…"]`, not into inline styles.
2. `.cloud-packed` is flipped on `<html>`, outside the LiveView container. Its absence is
   also the no-JavaScript fallback: `.cloud-words` stays a centred wrapping list.

### Stability

Placement is incremental. `_placed` maps word → its layout rectangle; on update only
words that are new (or whose measured box changed because their count crossed a
threshold) are placed, into the space left over. A full re-pack happens only when a word
genuinely cannot be placed, or once when `document.fonts.ready` resolves and every
measurement taken against the fallback face is stale.

A word's position in layout space is immutable once assigned. The one thing that does
move is the whole-cloud fit transform (`translate` + `scale` on the `<ul>`), which
re-centres and re-scales so the mass always fits the container; between re-packs it may
only *shrink*, never zoom back in, and it is animated over 700ms so an arriving word
settles the cloud rather than making the page pulse.

## Bug found during browser verification

The first implementation re-placed **every rotated word on every live update**, so words
visibly swapped positions mid-talk — precisely the failure mode this page cannot have.
Cause: the stored placement record carried the *collision* box, whose width and height
are swapped for a rotated word, and the "has this word's size changed?" check compared
that against the freshly *measured* box. It never matched, so every vertical word was
re-placed. Fixed by storing `measuredWidth`/`measuredHeight` alongside the collision box
and comparing against those. This is only observable in a browser under a real live
update — it is why the visual verification below is a gate and not a formality.

## Second round: the two-word cloud, and the review round

The first pass shipped with an honest weakness, visible in its own screenshot: a
cloud of **two** words rendered both vertical and both cyan — exactly the complaint that
opened this milestone. A per-word hash cannot promise anything about a *pair*, and with
two words the pair is the whole picture. The captain asked for contrast in tone *and*
orientation even when the room is tiny, for the tones to become real design tokens, and
for a grown word to stay in its neighbourhood.

### Neighbour rules that are still stable

`Style.decorate_all/1` now decorates the day's words **in first-appearance order** and
lets each word see the two that appeared before it:

| Rule | Why |
|---|---|
| Never the colour *family* of either of the two words before it | Two tokens is not two colours if the room cannot tell them apart: `accent` (hue 205) and `success` (hue 185) are one `:teal` family. Five families, so with two taken it always resolves. Looking back two also stops "a b a" stripes |
| Never vertical after a vertical word | Two verticals side by side read as a fence |
| Always vertical after two horizontal words (the day's start counts as horizontal) | Three horizontals in a row read as a list — and this is what gives a two-word cloud one of each |
| The first word of the day is horizontal | It anchors the cloud |

The realised vertical share is bounded by those rules alone — strictly between a third
and a half — and the hash only decides the free case.

**Why this does not restyle words mid-talk.** The order is over *every* word of the day,
qualifying or not (`WordCloud.build/2` now styles before applying the two-submission
threshold), and the day's feedback is append-only: it resets at WIB midnight, never in
the middle of a talk. A word's two predecessors are therefore fixed the moment it first
appears, so its tone and orientation are fixed too — even when a word that appeared
*earlier* only reaches the threshold *later* and slots in ahead of it. Tested directly
(`"an earlier word qualifying later does not restyle the words already shown"`) and as a
prefix property (`decorate_all(prefix) == take(decorate_all(full), n)`).

One edge remains: two submissions inserted in the **same second** are ordered by `id`
on reload (`list_feedback_for_date` sorts `desc: inserted_at, desc: id`) but by arrival
when live. A reconnect after that could swap two words' order, and with it their styles.
LiveView's rejoin patches the list in place rather than re-mounting the hook, so the
hook's incremental pass treats a changed `data-rotated` like a changed size and re-places
that word near where it sat; the ordering itself is noted, not fixed.

### Tones as design tokens

The two colours the cloud needed beyond the palette were first hard-coded, then (in the
review round) folded onto `--color-danger` and a `color-mix`. The captain chose instead
to add them to the design system: `--color-accent-amber` (`oklch(83% 0.15 85)`, "Console
Amber") and `--color-accent-rose` (`oklch(74% 0.17 350)`, "Chat Rose") now live in
`@theme` and in [DESIGN.md → Display accents](../../DESIGN.md), marked display-only so
the Console Rarity Rule still holds. `.cloud-tone-5/6` reference them.

### Review findings (all fixed in the review round, re-verified here)

1. *Resized word teleports* — `_spiral` now takes an `origin`; a word whose box grew is
   searched first within `CLOUD_NEAR_RADIUS` (260px) of where it sat. Browser-verified
   below: `mantap` grew from count 2 to 4 (level 1 → 2) and its centre moved **38px**.
2. *Unkeyed `<li>` animates the wrong word* — `id={"cloud-word-#{word}"}` so morphdom
   keys by word instead of position.
3. *Failed re-pack leaves state stale* — a re-pack that still cannot place a word now
   renders the partial state.
4. *Tautological font-size test* — replaced with two corpora differing only in another
   word's count.
5. *Off-theme tone colours* — superseded by the tokens above.

## Verification

`mix ci` green — format, `format --check-formatted`, `compile --warnings-as-errors`, `credo --strict`, dialyzer, `ex_dna --max-clones 0`, `reach.check`. Suite: **509 tests, 0 failures** (466 before this milestone; `test/notable/word_cloud/style_test.exs` covers tone, size variation, rotation and the neighbour rules; `test/notable/word_cloud_test.exs` covers the two-word cloud through `build/2` for sixty arbitrary pairs; `test/notable_web/live/feedback_cloud_live_test.exs` covers the rendered page).

Browser verification with `chrome-devtools-axi` (Chrome Canary) against the dev server,
seeded with 14 realistic Indonesian feedback submissions spaced 20s apart, producing 18
words across 3 size levels, all 6 tones, and 8 vertical; then two more submitted live
through the real donor form:

| Screenshot | What it shows |
|---|---|
| [`cloud-packed-1920.png`](screenshots/cloud-packed-1920.png) | `/cloud` at 1920×1080. Three visibly different sizes, all six colours, eight vertical words nested into the horizontals' gaps, a roughly elliptical mass with empty corners. No two neighbouring-in-time words share a colour family |
| [`cloud-packed-1280x720.png`](screenshots/cloud-packed-1280x720.png) | The same arrangement re-fitted to a smaller viewport — no clipping, no overflow (`scrollWidth == clientWidth`, `scrollHeight == clientHeight`) |
| [`cloud-packed-after-live-update.png`](screenshots/cloud-packed-after-live-update.png) | After `mantap, sesi interaktif` is submitted twice through `/`. `sesi` and `interaktif` are added into leftover gaps; `mantap` (count 2 → 4, level 1 → 2) is re-placed **38px** from its old centre; the other **17 rules are byte-identical** in the injected stylesheet. The fit scale only shrank (2.49 → 2.28) |
| [`cloud-packed-single-pair.png`](screenshots/cloud-packed-single-pair.png) | The minimum cloud, `materi bagus` twice: `materi` horizontal cyan, `bagus` vertical amber. Compare the first pass, where this pair came out both vertical and both cyan |
| [`cloud-packed-single-pair-2.png`](screenshots/cloud-packed-single-pair-2.png) | A second pair, `kodenya rapi`: `kodenya` horizontal slate, `rapi` vertical rose. Any pair gets one of each orientation and two colour families — the test covers sixty |
| [`cloud-overlay-1920.png`](screenshots/cloud-overlay-1920.png) | `/cloud-overlay`. `html`, `body` and the section all compute `rgba(0, 0, 0, 0)`; no header; `scrollHeight == clientHeight` and `scrollWidth == clientWidth` |
| [`cloud-no-js-fallback.png`](screenshots/cloud-no-js-fallback.png) | The pre-hook / no-JavaScript state (hook element detached, packed class and injected stylesheet removed): a readable centred wrapping list, not a heap of words at one point |

Viewport sweep at 1920×1080, 1280×720 and 820×640: no vertical or horizontal overflow at
any size, content inside the container with margin at all three, and the fit grows back
when the container grows.

## Deliberately not done

- The `font-display` face is still broken (`priv/static/fonts/notable-display.woff2` is
  the Vietnamese subset of Fraunces and has no Latin letters), so these words render in
  the fallback serif. That is the queued `notable-display-font-subset` task and was left
  alone. The layout measures whatever font resolves at runtime, which is correct either way.
- The current-WIB-day scope, the two-distinct-submissions rule and the blocklist are
  untouched.
