#!/usr/bin/env bash
#
# Rebuild priv/static/fonts/notable-display.woff2 from upstream Fraunces.
#
# The file this produces is the *display* face for the whole site: the header
# wordmark, every `font-display` heading, and the /cloud word cloud. It is built
# from github.com/undercasetype/Fraunces (SIL Open Font License 1.1) rather than
# copied off the Google Fonts CDN, because a CDN URL pins a version that rotates
# out from under you - which is how the shipped file ended up being Fraunces'
# *Vietnamese* subset, with no `N` in it, for three months.
#
# What it ships and why:
#
#   opsz=72   Fraunces is multi-axis (wght/opsz/SOFT/WONK). Optical size is
#             pinned, not left variable, so the CSS `@font-face` - which
#             declares weight only - is telling the whole truth about the file.
#             72pt is Fraunces' display cut. The poster cut (144pt) was measured
#             side by side and its verticals go hairline at the 18px header
#             wordmark, the same thinning the favicon work ran into; 72pt holds
#             up from 18px to a projector.
#   SOFT=0    the default: crisp terminals rather than the rounded "soft" cut.
#   WONK=1    the default: Fraunces' characterful swapped glyphs, which is the
#             reason to use this face at display sizes at all.
#   wght      left variable over 200-900, matching `font-weight: 200 900`.
#
# Coverage is Google's `latin` + `latin-ext` ranges. Indonesian orthography is
# basic Latin; latin-ext costs a few KB and covers pasted audience text.
#
# Requires: python3 with fonttools and brotli.
#   python3 -m pip install fonttools brotli
#
# Verify with: mix test test/notable_web/display_font_test.exs
set -euo pipefail

cd "$(dirname "$0")/../.."

# Pinned to an immutable upstream commit, not a branch: a branch ref rotates
# more freely than the CDN URL this script exists to avoid, and none of the
# tests can tell a drifted rebuild from an intended one - glyph coverage, the
# axis assertion and the OFL notice are all version-independent. Upgrading
# Fraunces is a deliberate act: bump UPSTREAM_SHA *and* UPSTREAM_SHA256
# together, re-run this script, and re-run the tests to see what moved.
#
# 7ccdec3 is Fraunces v1.003 (the commit `master` pointed at on 2026-08-25).
UPSTREAM_SHA="7ccdec31c6028118dce3e47fe864e3744460371d"
UPSTREAM_SHA256="0776a870a0856b296e11639505ac0cf9be5e7800bb1849dfa21a1bd182455fc0"

UPSTREAM="https://raw.githubusercontent.com/undercasetype/Fraunces/$UPSTREAM_SHA/fonts/variable/Fraunces%5BSOFT%2CWONK%2Copsz%2Cwght%5D.ttf"
OFL_URL="https://raw.githubusercontent.com/undercasetype/Fraunces/$UPSTREAM_SHA/OFL.txt"

LATIN='U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+2074,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD'
LATIN_EXT='U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Everything downloads and builds inside "$work". The tracked files under
# priv/static/fonts/ are only overwritten once the build has succeeded, so a
# failed run cannot leave a clobbered licence notice or a truncated font
# behind. `--fail` makes an HTTP error a non-zero exit under `set -e` instead
# of curl cheerfully writing "404: Not Found" into the target file.
echo "==> downloading upstream Fraunces ($UPSTREAM_SHA)"
curl -fsSL -o "$work/fraunces.ttf" "$UPSTREAM"
curl -fsSL -o "$work/OFL.txt" "$OFL_URL"

actual="$(sha256_of "$work/fraunces.ttf")"
if [ "$actual" != "$UPSTREAM_SHA256" ]; then
  echo "error: upstream Fraunces does not match the recorded pin." >&2
  echo "  expected sha256 $UPSTREAM_SHA256" >&2
  echo "  actual   sha256 $actual" >&2
  echo "If this is an intended upgrade, update UPSTREAM_SHA and UPSTREAM_SHA256" >&2
  echo "together and re-run mix test test/notable_web/display_font_test.exs." >&2
  exit 1
fi

echo "==> instancing to a weight-only display cut"
python3 -m fontTools.varLib.instancer "$work/fraunces.ttf" \
  opsz=72 SOFT=0 WONK=1 'wght=200:400:900' -o "$work/instance.ttf"

echo "==> subsetting to latin + latin-ext"
python3 -m fontTools.subset "$work/instance.ttf" \
  --unicodes="$LATIN,$LATIN_EXT" \
  --layout-features='*' \
  --name-IDs='*' \
  --output-file="$work/subset.ttf"

# The instancer prunes the name table and renames the family after the default
# instance ("Fraunces Black"), which drops the OFL notice the licence asks us to
# keep with the font and leaves a misleading identity spread across the family
# (1/2), typographic family (16/17), full name (4), PostScript names (3/6/25).
# Put the notice back and rewrite every one of those records, so the shipped
# file has no half-renamed "Fraunces Black" identity left in it.
echo "==> restoring family name and the OFL notice"
python3 - "$work/fraunces.ttf" "$work/subset.ttf" "$work/named.ttf" <<'PY'
import sys
from fontTools.ttLib import TTFont

source, subset_path, out = sys.argv[1:4]
src, font = TTFont(source, lazy=True), TTFont(subset_path)
name = font["name"]

WINDOWS = (3, 1, 0x409)

# 0 copyright, 13 licence description, 14 licence URL - carried from upstream.
for name_id in (0, 13, 14):
    record = src["name"].getDebugName(name_id)
    if record:
        name.setName(record, name_id, *WINDOWS)

FAMILY = "Notable Display"
SUBFAMILY = "Regular"
POSTSCRIPT = "NotableDisplay-Regular"

version = (name.getDebugName(5) or "Version 1.000").removeprefix("Version ").strip()

renames = {
    1: FAMILY,
    2: SUBFAMILY,
    3: f"{version};UCT;{POSTSCRIPT}",
    4: FAMILY,
    6: POSTSCRIPT,
    16: FAMILY,
    17: SUBFAMILY,
    25: "NotableDisplay",
}

for name_id, value in renames.items():
    name.setName(value, name_id, *WINDOWS)

# Drop any duplicate records left on other platform/encoding rows, so the
# Macintosh table cannot keep serving the old identity beside the new one.
name.names = [
    record
    for record in name.names
    if record.nameID not in renames
    or (record.platformID, record.platEncID, record.langID) == WINDOWS
]

font.save(out)
PY

echo "==> flavouring as woff2"
python3 - "$work/named.ttf" "$work/notable-display.woff2" <<'PY'
import sys
from fontTools.ttLib import TTFont

font = TTFont(sys.argv[1])
font.flavor = "woff2"
font.save(sys.argv[2])
PY

echo "==> installing into priv/static/fonts"
cp "$work/notable-display.woff2" priv/static/fonts/notable-display.woff2
cp "$work/OFL.txt" priv/static/fonts/notable-display.LICENSE.txt

ls -l priv/static/fonts/notable-display.woff2
