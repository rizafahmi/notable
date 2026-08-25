# Milestone 17 — Display font actually renders

Status: **complete** (2026-08-25)

## The bug

`priv/static/fonts/notable-display.woff2` had been Fraunces' **Vietnamese**
subset since `afab09e` (2026-05-03): 111 codepoints — Vietnamese diacritics,
space, `A`, and the dong sign. No `N`, `o`, `t`, `b`, `l` or `e`.

Google Fonts serves Fraunces as three `@font-face` blocks in the order
`/* vietnamese */`, `/* latin-ext */`, `/* latin */`. Whoever saved the file took
the first URL.

Nothing failed. The font loaded, `document.fonts.check()` returned true, and
every character the site actually draws fell through to the browser's
last-resort face. The header wordmark, every `font-display` heading, and the
`/cloud` word cloud have never once rendered in Fraunces.

The second defect hid the first: `--font-display` named exactly one family, so
the fallback was whatever the browser felt like rather than a chosen serif.

## What shipped

**The font.** Built from upstream `github.com/undercasetype/Fraunces` v1.003
(SIL OFL 1.1) by [`scripts/fonts/build-display-font.sh`](../../../scripts/fonts/build-display-font.sh),
not scraped from the Google CDN — a CDN URL pins a version that rotates, which
is the mechanism that produced this bug. The script is the record of the
instance choice; re-run it to rebuild.

Upstream is pinned to commit `7ccdec3` (what `master` pointed at on 2026-08-25)
and the downloaded variable font's sha256 is recorded in the script and checked
after download, because a branch ref rotates more freely than the CDN URL the
script exists to avoid, and nothing in the test suite can tell a drifted
rebuild from an intended one — glyph coverage, the axis assertion and the OFL
notice are all version-independent. Upgrading Fraunces means bumping
`UPSTREAM_SHA` and `UPSTREAM_SHA256` together and re-running the tests. Both
downloads use `curl --fail` and land in a temp dir; `priv/static/fonts/` is only
overwritten once the build succeeds, so a failed run cannot leave the tracked
OFL notice replaced by a `404: Not Found` body.

Instance: **weight-only, `opsz=72`, `SOFT=0`, `WONK=1`, `wght` variable 200–900.**

`fontTools.varLib.instancer` renames the font after its default instance, and
that name lands in more records than the family pair — name IDs 3, 4, 6, 16/17
and 25 as well as 1/2, with 16/17 taking precedence over 1/2 where both exist.
The script rewrites all of them to the `Notable Display` identity while keeping
the provenance records (0 copyright, 13 licence description, 14 licence URL)
carried over from upstream. `display_font_test.exs` asserts that consistency, so
a future rebuild cannot half-rename.

Fraunces has four axes and the `@font-face` declares weight only, so the other
three are pinned rather than left variable for the browser to default. Optical
size was chosen by measurement, not taste — see
`screenshots/opsz-specimen.png`, which renders the same three strings through
`opsz=144`, `opsz=72`, and a variable-`opsz` build with
`font-optical-sizing: auto`:

- `opsz=144` (the poster cut) goes hairline at the 18px header wordmark — the
  same thinning the favicon investigation hit at small sizes.
- variable `opsz` + `font-optical-sizing: auto` looks best across the range but
  doubles the file (138 KB vs 75 KB) and needs the CSS to declare the axis.
- `opsz=72` is Fraunces' display cut and holds from the 18px wordmark up to the
  word cloud on a projector. That is the whole range the site uses.

Coverage is Google's `latin` + `latin-ext` ranges — 514 codepoints, 75 KB.
Indonesian orthography is basic Latin; `latin-ext` costs a few KB and covers
pasted audience text in the word cloud.

Licence: the OFL text ships at
`priv/static/fonts/notable-display.LICENSE.txt` (reachable at
`/fonts/notable-display.LICENSE.txt`, since `fonts` is already in
`NotableWeb.static_paths/0`), and the build script restores name IDs 0/13/14 —
copyright, licence description, licence URL — which `fontTools.varLib.instancer`
prunes. Family name is set to `Notable Display` to match the `@font-face`;
provenance lives in the copyright record.

**The fallback stack.** `assets/css/app.css`:

```css
--font-display: "Notable Display", Fraunces, Georgia, "Times New Roman", serif;
```

## Tests (written first, red before the fix)

`test/notable_web/display_font_test.exs` — 9 tests, all failing on the old file
and old CSS (7 of 9 red at the start; the two that passed were the wordmark-first
family check and the "is Fraunces" name check).

It reads the **shipped binary** through `Notable.FontProbe`
(`test/support/font_probe.ex` + `font_probe.py`), which mirrors the
`Notable.QrDecode` pattern: a WOFF2 table directory is Brotli-compressed, so the
parsing lives in a small Python helper rather than in the BEAM.

Asserts:
- every letter of "Notable" has a glyph
- every heading string the site renders in the display face has glyphs,
  including the `…` in `/cloud`'s empty state and the `&` in the donate page
- printable ASCII is covered wholesale, which bounds word-cloud words
- the file carries the SIL Open Font License notice
- **`wght` is the only variation axis** — a multi-axis file would let the
  browser default axes the CSS never mentions
- `--font-display` names more than one family, starts with `"Notable Display"`,
  and ends in a generic family

CI gained `fonttools brotli` alongside the existing OpenCV install.

## Evidence

- `screenshots/wordmark-compare.png` — the header wordmark and `Tanya Jawab`
  at 3×, before and after, on the real dark background. Before is the browser's
  Didone-ish default (ball terminals, thin joins). After is Fraunces: flat slab
  serifs, the wonked `a` and `J`, sturdier stems.
- `screenshots/before-questions.png` / `after-questions.png` — full `/questions`
  page, same viewport.
- `screenshots/after-cloud.png` — `/cloud` at display size, with the `…` the old
  subset could render and the words it could not.
- `screenshots/after-fallback.png` — the same header with the webfont URL
  404'd. Measured in-page against known families, the stack resolves to
  **Georgia** (223.03px for "Notable" at 64px, matching Georgia exactly;
  Fraunces is not installed on the machine, and the browser default measured
  202.59px). That is the degradation the second half of the fix buys.
- `mix ci`: 476 tests, 0 failures; credo clean; dialyzer 0 errors.

## Not touched

Favicon and app icons — separate drawn artwork, already shipped.
`/cloud` rendering (`feedback_cloud_live.ex`, `word_cloud.ex`, `app.js`) — owned
by a concurrent change.
