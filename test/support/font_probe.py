#!/usr/bin/env python3
"""Report what a shipped font file actually covers, for the Elixir test suite.

Reads a single JSON argument and prints a JSON result on stdout:

  {"path": "priv/static/fonts/notable-display.woff2"}

The result carries the family/subfamily names, the variation axes with their
ranges and defaults, and the set of Unicode codepoints in the font's cmap.
The suite uses that last part to prove the file contains glyphs for the text
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

    names = {}
    for record in font["name"].names:
        # 1 = family, 2 = subfamily, 0 = copyright, 13 = licence, 14 = licence URL
        if record.nameID in (0, 1, 2, 13, 14):
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
