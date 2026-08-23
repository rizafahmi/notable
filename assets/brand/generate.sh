#!/usr/bin/env bash
# Regenerate Notable's brand raster assets from their vector sources.
#
# Every PNG is rasterised NATIVELY at its target size. Do not render one large
# PNG and downscale: measured on this icon, rendering at 64px and resizing to
# 16px washed a 1.75px stroke out to ~12% opacity (28 pixels at value 225),
# while native rasterisation kept it solid (48 pure-black pixels).
#
# ImageMagick must be backed by librsvg, not its own MSVG renderer:
#   magick -list format | grep SVG   # => "SVG rw+ ... (RSVG 2.62.3)"
#
# Density maths: the icon sources declare an intrinsic 64px at 96dpi, so
# density = 96 * target / 64 = 1.5 * target. og-image.svg is already 1200x630,
# so it renders at density 96.

set -euo pipefail
cd "$(dirname "$0")/../.."

STATIC="priv/static"
SRC="assets/brand"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v magick >/dev/null || { echo "magick not found" >&2; exit 1; }
magick -list format | grep -qi 'SVG.*RSVG' || {
  echo "ImageMagick is not backed by librsvg; output would be unreliable" >&2; exit 1; }

echo "==> favicon.ico (true multi-size ICO: 16 + 32 + 48)"
magick -background none -density 24 "$STATIC/favicon.svg" "$TMP/icon-16.png"
magick -background none -density 48 "$STATIC/favicon.svg" "$TMP/icon-32.png"
magick -background none -density 72 "$STATIC/favicon.svg" "$TMP/icon-48.png"
magick "$TMP/icon-16.png" "$TMP/icon-32.png" "$TMP/icon-48.png" "$STATIC/favicon.ico"

echo "==> apple-touch-icon.png (180, full bleed, alpha stripped)"
# iOS ignores the source's own rounding and renders alpha as black, so this uses
# the full-bleed source and is flattened onto the brand surface colour.
# PNG24: forces 8-bit truecolour - without it ImageMagick emits a palette PNG,
# and Apple's guidance is a plain opaque truecolour image.
magick -background "#071117" -density 270 "$SRC/app-icon.svg" \
  -alpha remove -alpha off PNG24:"$STATIC/apple-touch-icon.png"

echo "==> icon-192.png / icon-512.png (web manifest)"
# PNG32: pins 8-bit RGBA; the default here is 16-bit, which doubles the bytes
# for no visible gain on a flat two-colour mark.
magick -background none -density 288 "$STATIC/favicon.svg" PNG32:"$STATIC/icon-192.png"
magick -background none -density 768 "$STATIC/favicon.svg" PNG32:"$STATIC/icon-512.png"

echo "==> og-image.png (1200x630)"
magick -background none -density 96 "$SRC/og-image.svg" \
  -alpha remove -alpha off PNG24:"$STATIC/og-image.png"

echo
echo "==> verification"
file "$STATIC/favicon.ico"
magick identify "$STATIC/favicon.ico"
magick identify "$STATIC/apple-touch-icon.png" "$STATIC/icon-192.png" \
  "$STATIC/icon-512.png" "$STATIC/og-image.png"
