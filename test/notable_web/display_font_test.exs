defmodule NotableWeb.DisplayFontTest do
  @moduledoc """
  Guards the display typeface end to end.

  `priv/static/fonts/notable-display.woff2` shipped for months as Fraunces'
  *Vietnamese* subset - 111 codepoints with no `N`, `o`, `t`, `b`, `l` or `e` -
  so the "Notable" wordmark and every `font-display` heading silently fell back
  to the browser default. Nothing failed; the glyphs just were not there. These
  tests read the shipped binary and assert coverage of the text the site
  actually draws in that face, and assert the CSS keeps a real fallback stack so
  a future subset mistake degrades to Georgia rather than to nothing.
  """
  use ExUnit.Case, async: true

  alias Notable.FontProbe

  @font "priv/static/fonts/notable-display.woff2"
  @css "assets/css/app.css"

  # Every string the site renders through `font-display`, gathered from the
  # `font-display` class sites in lib/notable_web. Word-cloud words are audience
  # free text, so basic Latin has to be covered wholesale as well.
  @display_text [
    "Notable",
    "Tanya Jawab",
    "Moderasi Pertanyaan",
    "Scan QRIS untuk Apresiasi",
    "Terima kasih! Pesan dan tip Anda telah tersimpan.",
    "Terima kasih! Pesan Anda telah kami simpan.",
    "Kirim Masukan & Pesan",
    "Menunggu suara ruangan…"
  ]

  @ascii_printable Enum.map_join(0x20..0x7E, &<<&1::utf8>>)

  setup_all do
    unless FontProbe.available?() do
      flunk("""
      python3 with fontTools and brotli is required to inspect the display font.
      Install it with: python3 -m pip install fonttools brotli
      """)
    end

    {:ok, report} = FontProbe.inspect_font(@font)
    %{font: report}
  end

  describe "shipped display font" do
    test "covers the Notable wordmark", %{font: font} do
      assert FontProbe.missing(font, "Notable") == [],
             "the wordmark in the header cannot render without these glyphs"
    end

    test "covers every heading the site renders in the display face", %{font: font} do
      for text <- @display_text do
        assert FontProbe.missing(font, text) == [],
               "display heading #{inspect(text)} is missing glyphs"
      end
    end

    test "covers printable ASCII, which bounds Indonesian word-cloud words", %{font: font} do
      assert FontProbe.missing(font, @ascii_printable) == []
    end

    test "is Fraunces", %{font: font} do
      # The family is renamed to match the @font-face, so provenance lives in
      # the copyright record rather than the family name.
      assert font.names["1"] == "Notable Display"
      assert font.names["0"] =~ "Fraunces"
    end

    test "carries the SIL Open Font License notice the OFL requires", %{font: font} do
      notice = Enum.join([font.names["0"] || "", font.names["13"] || ""], " ")
      assert notice =~ "Open Font License"
    end

    test "exposes no variation axis the @font-face does not declare", %{font: font} do
      # The CSS declares `font-weight: 200 900` and nothing else. Fraunces also
      # has opsz/SOFT/WONK; shipping them variable would let the browser pick
      # defaults for axes the stylesheet never mentions.
      assert Enum.map(font.axes, & &1["tag"]) == ["wght"]

      assert [%{"min" => 200.0, "max" => 900.0}] = font.axes
    end
  end

  describe "--font-display fallback stack" do
    setup do
      css = File.read!(@css)

      [_, value] = Regex.run(~r/--font-display:\s*([^;]+);/s, css)
      %{families: value |> String.split(",") |> Enum.map(&String.trim/1)}
    end

    test "names more than one family", %{families: families} do
      assert length(families) > 1,
             "a single-family --font-display drops to the browser default when the webfont fails"
    end

    test "starts with the webfont family", %{families: [first | _]} do
      assert first == ~s("Notable Display")
    end

    test "ends in a generic family so the last resort is still a serif", %{families: families} do
      assert List.last(families) in ~w(serif sans-serif ui-serif)
    end
  end
end
