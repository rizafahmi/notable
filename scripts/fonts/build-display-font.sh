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

UPSTREAM="https://raw.githubusercontent.com/undercasetype/Fraunces/master/fonts/variable/Fraunces%5BSOFT%2CWONK%2Copsz%2Cwght%5D.ttf"
OFL_URL="https://raw.githubusercontent.com/undercasetype/Fraunces/master/OFL.txt"

LATIN='U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+2074,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD'
LATIN_EXT='U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> downloading upstream Fraunces"
curl -sSL -o "$work/fraunces.ttf" "$UPSTREAM"
curl -sSL -o priv/static/fonts/notable-display.LICENSE.txt "$OFL_URL"

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
# keep with the font and leaves a misleading family name. Put both back.
echo "==> restoring family name and the OFL notice"
python3 - "$work/fraunces.ttf" "$work/subset.ttf" "$work/named.ttf" <<'PY'
import sys
from fontTools.ttLib import TTFont

source, subset_path, out = sys.argv[1:4]
src, font = TTFont(source, lazy=True), TTFont(subset_path)
name = font["name"]

# 0 copyright, 13 licence description, 14 licence URL - carried from upstream.
for name_id in (0, 13, 14):
    record = src["name"].getDebugName(name_id)
    if record:
        name.setName(record, name_id, 3, 1, 0x409)

name.setName("Notable Display", 1, 3, 1, 0x409)
name.setName("Regular", 2, 3, 1, 0x409)
font.save(out)
PY

echo "==> flavouring as woff2"
python3 - "$work/named.ttf" priv/static/fonts/notable-display.woff2 <<'PY'
import sys
from fontTools.ttLib import TTFont

font = TTFont(sys.argv[1])
font.flavor = "woff2"
font.save(sys.argv[2])
PY

ls -l priv/static/fonts/notable-display.woff2
