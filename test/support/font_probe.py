#!/usr/bin/env python3
"""Report what a shipped font file actually covers, for the Elixir test suite.

Reads a single JSON argument and prints a JSON result on stdout:

  {"path": "priv/static/fonts/notable-display.woff2"}

The result carries every name-table record keyed by name ID, the variation
axes with their ranges and defaults, and the set of Unicode codepoints in the
font's cmap. The suite uses that last part to prove the file contains glyphs for the text
the site renders in the display face - a subset that omits `N` still loads
without error, which is exactly how the Vietnamese-only subset went unnoticed.
"""

import json
import sys

from fontTools.ttLib import TTFont


def main():
    spec = json.loads(sys.argv[1])
    font = TTFont(spec["path"], lazy=True)

    axes = [
        {
            "tag": axis.axisTag,
            "min": axis.minValue,
            "default": axis.defaultValue,
            "max": axis.maxValue,
        }
        for axis in (font["fvar"].axes if "fvar" in font else [])
    ]

    # Every name record, keyed by name ID. The suite needs more than the family
    # pair: instancing renames the font after its default instance and spreads
    # that identity across IDs 1/2, 3, 4, 6, 16/17 and 25, so a half-finished
    # rename is only visible when the whole table is reported.
    names = {}
    for record in font["name"].names:
        names.setdefault(str(record.nameID), record.toUnicode())

    print(
        json.dumps(
            {
                "codepoints": sorted(font.getBestCmap().keys()),
                "axes": axes,
                "names": names,
                "glyph_count": len(font.getGlyphOrder()),
            }
        )
    )


if __name__ == "__main__":
    main()
