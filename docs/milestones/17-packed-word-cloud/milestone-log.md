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
| **placement only** | `Hooks.WordCloud` in `assets/js/app.js` | verified in a real browser (below) |

`Notable.WordCloud.Style` derives everything from a local **FNV-1a** hash of the word,
salted per aspect (`"tone:"`, `"size:"`, `"spin:"`) so tone, size and rotation are
independent — a single hash would have made every rotated word share a colour. FNV-1a
rather than `:erlang.phash2/1` so the mapping is fixed by this module, not by the runtime.

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

## Verification

`mix ci` green — format, `format --check-formatted`, `compile --warnings-as-errors`, `credo --strict`, dialyzer, `ex_dna --max-clones 0`, `reach.check`. Suite: **494 tests, 0 failures** (466 before; +17 in `test/notable/word_cloud/style_test.exs`, +11 in `test/notable_web/live/feedback_cloud_live_test.exs`).

Browser verification with `chrome-devtools-axi` (Chrome Canary) against the dev server,
seeded with 14 realistic Indonesian feedback submissions producing 16 words across 4
size levels, all 6 tones, and 6 rotated:

| Screenshot | What it shows |
|---|---|
| [`cloud-packed-1920.png`](screenshots/cloud-packed-1920.png) | `/cloud` at 1920×1080. Four visibly different sizes, all six colours, six vertical words, short words nested into tall words' gaps, roughly elliptical mass with empty corners |
| [`cloud-packed-1280x720.png`](screenshots/cloud-packed-1280x720.png) | The same arrangement re-fitted to a smaller viewport — no clipping, no overflow |
| [`cloud-packed-after-live-update.png`](screenshots/cloud-packed-after-live-update.png) | After two feedback submissions arrive live. `sesi` and `interaktif` are added; **zero** already-placed words moved in layout space (diffed rule-by-rule from the injected stylesheet) |
| [`cloud-packed-single-pair.png`](screenshots/cloud-packed-single-pair.png) | The minimum cloud: one word pair. Both words hash to rotated and to the same tone here — that is the honest output of a per-word hash with a 6-colour palette, not a bug |
| [`cloud-packed-single-pair-horizontal.png`](screenshots/cloud-packed-single-pair-horizontal.png) | A second pair, both at count 2: two colours, two sizes, nested — the equal-count case at minimum scale |
| [`cloud-overlay-1920.png`](screenshots/cloud-overlay-1920.png) | `/cloud-overlay`. `html`, `body` and the section all compute `rgba(0, 0, 0, 0)`; no header; `scrollHeight == clientHeight` and `scrollWidth == clientWidth` |
| [`cloud-no-js-fallback.png`](screenshots/cloud-no-js-fallback.png) | The pre-hook / no-JavaScript state (packed class and injected stylesheet removed): a readable centred wrapping list, not a heap of words at one point |

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
