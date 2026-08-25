defmodule Notable.FontProbe do
  @moduledoc """
  Inspects a shipped font binary through `fontTools`, mirroring the
  `Notable.QrDecode` pattern: the parsing lives in a small Python helper because
  reading a `.woff2` means Brotli-decompressing its table directory, which the
  BEAM has no built-in answer for.

  Used by `NotableWeb.DisplayFontTest` to assert the display face actually
  contains the characters the site draws with it.
  """

  @script Path.expand("font_probe.py", __DIR__)

  @type report :: %{
          codepoints: MapSet.t(non_neg_integer()),
          axes: [map()],
          names: %{optional(String.t()) => String.t()},
          glyph_count: non_neg_integer()
        }

  @doc """
  Returns true when `fontTools` (and the Brotli codec it needs for WOFF2) is
  importable, so tests can explain the missing tool rather than fail obscurely.
  """
  @spec available?() :: boolean()
  def available? do
    case System.cmd("python3", ["-c", "import fontTools.ttLib, brotli"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  @doc """
  Reads `path` and returns `{:ok, report}` or `{:error, reason}`.
  """
  @spec inspect_font(Path.t()) :: {:ok, report()} | {:error, term()}
  def inspect_font(path) do
    case System.cmd("python3", [@script, JSON.encode!(%{path: path})], stderr_to_stdout: true) do
      {output, 0} ->
        %{"codepoints" => codepoints, "axes" => axes, "names" => names, "glyph_count" => count} =
          JSON.decode!(output)

        {:ok,
         %{
           codepoints: MapSet.new(codepoints),
           axes: axes,
           names: names,
           glyph_count: count
         }}

      {output, status} ->
        {:error, "font_probe.py exited #{status}: #{output}"}
    end
  end

  @doc """
  Returns the characters of `text` that the font has no glyph for.
  """
  @spec missing(report(), String.t()) :: [String.t()]
  def missing(%{codepoints: codepoints}, text) do
    text
    |> String.to_charlist()
    |> Enum.reject(&MapSet.member?(codepoints, &1))
    |> Enum.uniq()
    |> Enum.map(&<<&1::utf8>>)
  end
end
