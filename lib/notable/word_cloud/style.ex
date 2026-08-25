defmodule Notable.WordCloud.Style do
  @moduledoc """
  Per-word appearance for the rendered cloud: colour, size and rotation.

  Everything a word looks like is decided here, in Elixir, and handed to the
  browser as attributes. The layout hook in `assets/js/app.js` only *places*
  the rendered words; it never picks a colour, a size or a rotation. That split
  is deliberate — this project has no JavaScript test runner, so any decision
  that can be unit-tested belongs on this side of the wire.

  ## Colour is a function of the word, not of the count

  Colour used to be derived from `level`, which meant equal counts always
  produced an identical colour. In a small room every qualifying word sits at
  exactly the minimum count, so the whole cloud rendered in a single colour.
  Tone is therefore hashed from the word itself: stable across re-renders,
  identical on `/cloud` and `/cloud-overlay`, and independent of how the talk
  is going.

  ## Size still comes from the count

  `Notable.WordCloud` keeps deciding the size *band* from absolute count
  thresholds — see its moduledoc for why relative sizing is wrong on a
  projector. This module only varies the size *within* a band, again as a pure
  function of the word, so a room where everything is mentioned twice still
  produces a ragged mass rather than a uniform wall.

  The bands never overlap (`base_font_size(n) * high < base_font_size(n + 1) *
  low`), so a more-mentioned word is still always the visibly bigger one.

  ## Determinism

  Every derivation runs through a local FNV-1a hash rather than
  `:erlang.phash2/1`, so the mapping is fixed by this module and not by the
  runtime. A word's appearance therefore never changes mid-talk.
  """

  import Bitwise

  @tones [1, 2, 3, 4, 5, 6]

  # Base size per level, in rem. The browser scales the finished cloud to fit
  # its container, so these are relative weights first and absolute sizes only
  # incidentally.
  @base_font_sizes %{1 => 3.0, 2 => 4.2, 3 => 5.8, 4 => 8.0, 5 => 11.0}

  # Narrow enough that the level bands stay disjoint, wide enough to read as
  # deliberate raggedness rather than a rendering accident.
  @variations [0.88, 0.94, 1.0, 1.06, 1.12]

  # Share of words rendered vertically, in percent.
  @rotated_share 25

  @tone_salt "tone:"
  @variation_salt "size:"
  @rotation_salt "spin:"

  @fnv_offset 2_166_136_261
  @fnv_prime 16_777_619
  @mask 0xFFFFFFFF

  @doc "Every tone a word may be given."
  def tones, do: @tones

  @doc "The tone for `word`, stable for the life of the word."
  def tone(word) when is_binary(word) do
    Enum.at(@tones, rem(hash(@tone_salt, word), length(@tones)))
  end

  @doc "The tone as the CSS class that paints it (see `assets/css/app.css`)."
  def tone_class(word) when is_binary(word), do: "cloud-tone-#{tone(word)}"

  @doc "The inclusive `{low, high}` bounds of `size_variation/1`."
  def size_variation_range, do: {Enum.min(@variations), Enum.max(@variations)}

  @doc "The multiplier applied to this word's level base size."
  def size_variation(word) when is_binary(word) do
    Enum.at(@variations, rem(hash(@variation_salt, word), length(@variations)))
  end

  @doc "The unvaried size, in rem, of a word at `level`."
  def base_font_size(level) when is_integer(level) do
    Map.get(@base_font_sizes, level, @base_font_sizes[1])
  end

  @doc "The rendered size, in rem, of `word` at `level`."
  def font_size(word, level) when is_binary(word) and is_integer(level) do
    Float.round(base_font_size(level) * size_variation(word), 3)
  end

  @doc "Whether `word` renders vertically."
  def rotated?(word) when is_binary(word) do
    rem(hash(@rotation_salt, word), 100) < @rotated_share
  end

  @doc """
  Adds `:tone`, `:tone_class`, `:font_size` and `:rotated` to a built word.

  Called by `Notable.WordCloud.build/2` so every surface renders the same word
  the same way.
  """
  def decorate(%{word: word, level: level} = entry) do
    entry
    |> Map.put(:tone, tone(word))
    |> Map.put(:tone_class, tone_class(word))
    |> Map.put(:font_size, font_size(word, level))
    |> Map.put(:rotated, rotated?(word))
  end

  # FNV-1a, 32-bit. Salted so tone, size and rotation vary independently: a
  # single hash would make every rotated word share a colour.
  defp hash(salt, word) do
    (salt <> word)
    |> :binary.bin_to_list()
    |> Enum.reduce(@fnv_offset, fn byte, acc ->
      acc |> bxor(byte) |> Kernel.*(@fnv_prime) |> band(@mask)
    end)
  end
end
