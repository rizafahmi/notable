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

  ## Neighbours contrast, and why that is still stable

  A per-word hash cannot promise anything about a *pair*: two words can always
  land on the same tone, or both on vertical, and with a two-word cloud that
  is the whole picture — which is exactly the complaint that started this
  work. So `decorate_all/1` decorates the day's words **in first-appearance
  order** and lets each word see the two words that appeared before it: a word
  never wears either of their colour families (`accent` and `success` are both
  a teal to the room), is never vertical after a vertical word,
  and is always vertical after two horizontal ones — so the first word of the
  day is horizontal and the second stands up beside it.

  That order is over *every* word of the day, qualifying or not, and the day's
  feedback is append-only (it resets at WIB midnight, never in the middle of a
  talk). A word's predecessors are therefore fixed the moment it first
  appears, so its appearance is fixed too — even when a word that appeared
  earlier only reaches the display threshold later and slots in ahead of it.

  ## Determinism

  Every derivation runs through a local FNV-1a hash rather than
  `:erlang.phash2/1`, so the mapping is fixed by this module and not by the
  runtime. A word's appearance therefore never changes mid-talk.
  """

  import Bitwise

  @tones [1, 2, 3, 4, 5, 6]

  # Which tones the room cannot tell apart. `accent` (hue 205) and `success`
  # (hue 185) are both a bright teal on a projector, so neighbours are kept
  # distinct by family, not merely by token. Painted in `assets/css/app.css`.
  @tone_families %{1 => :slate, 2 => :teal, 3 => :purple, 4 => :teal, 5 => :amber, 6 => :rose}

  # Base size per level, in rem. The browser scales the finished cloud to fit
  # its container, so these are relative weights first and absolute sizes only
  # incidentally.
  @base_font_sizes %{1 => 3.0, 2 => 4.2, 3 => 5.8, 4 => 8.0, 5 => 11.0}

  # Narrow enough that the level bands stay disjoint, wide enough to read as
  # deliberate raggedness rather than a rendering accident.
  @variations [0.88, 0.94, 1.0, 1.06, 1.12]

  # Share of words whose *own* hash says vertical, in percent. The neighbour
  # rules in `rotated?/2` bound the realised share to between a third and a
  # half regardless; this only decides how often the free choice stands up.
  @rotated_share 25

  # How many predecessors a word is decided against. One is enough for the
  # two-word case; two means a word is also never the colour of the word before
  # its neighbour (no "a b a" stripes) and never the third horizontal in a row.
  @lookback 2

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

  @doc "The colour family of a tone — what a room actually sees."
  def tone_family(tone) when is_map_key(@tone_families, tone), do: @tone_families[tone]

  @doc "A tone as the CSS class that paints it (see `assets/css/app.css`)."
  def tone_class(tone) when tone in @tones, do: "cloud-tone-#{tone}"

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
  The tone for `word` given the tones its neighbours already wear.

  The word's own hashed tone wins unless its *family* is already worn; then
  the next tone along the palette whose family is not. `taken` is at most
  two tones and there are five families, so this always resolves.
  """
  def tone(word, taken) when is_binary(word) and is_list(taken) do
    start = rem(hash(@tone_salt, word), length(@tones))
    worn = Enum.map(taken, &tone_family/1)

    @tones
    |> Stream.cycle()
    |> Stream.drop(start)
    |> Enum.find(&(tone_family(&1) not in worn))
  end

  @doc """
  Whether `word` renders vertically, given the orientations of up to two
  words before it, nearest first. `[]` is the first word of the day, which is
  always horizontal; before it, the day's start counts as horizontal.

  Two vertical words side by side read as a fence, so a word after a vertical
  one is always horizontal. Three horizontal words in a row read as a list,
  so a word after two horizontal ones is always vertical — which is what
  gives a two-word cloud one of each: the first word of the day anchors the
  cloud horizontally, and the second stands up beside it. In between, the
  word's own hashed rotation decides.
  """
  def rotated?(word, []) when is_binary(word), do: false

  def rotated?(word, previous) when is_binary(word) and is_list(previous) do
    case Enum.take(previous ++ [false], 2) do
      [true | _] -> false
      [false, false] -> true
      [false, true] -> rotated?(word)
    end
  end

  @doc """
  Decorates every word of the day, given in first-appearance order.

  Adds `:tone`, `:tone_class`, `:font_size` and `:rotated` to each entry.
  Called by `Notable.WordCloud.build/2` before the display threshold is
  applied, so a word's appearance is decided against the words that appeared
  before it, whether or not they are shown — see the moduledoc for why that
  is what keeps it stable.
  """
  def decorate_all(entries) when is_list(entries) do
    entries
    |> Enum.reduce({[], []}, fn %{word: word, level: level} = entry, {done, recent} ->
      decorated =
        entry
        |> Map.put(:tone, tone(word, Enum.map(recent, & &1.tone)))
        |> Map.put(:font_size, font_size(word, level))
        |> Map.put(:rotated, rotated?(word, Enum.map(recent, & &1.rotated)))
        |> then(&Map.put(&1, :tone_class, tone_class(&1.tone)))

      {[decorated | done], Enum.take([decorated | recent], @lookback)}
    end)
    |> elem(0)
    |> Enum.reverse()
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
