defmodule Notable.WordCloud do
  @moduledoc """
  Turns audience feedback messages into a ranked, weighted word cloud.

  Pure functions only — no repo, no process state — so the whole ranking
  contract is unit-testable directly.

  ## Safety rules

  This output goes on a screen in front of a live room, and stored feedback
  carries no moderation state, so two hard display-time rules gate every word:

  1. A word renders only when it appears in **at least two distinct
     submissions**. One person cannot put a word on the wall,
     however many times they repeat it.
  2. Words on the profanity/slur blocklist in `Notable.WordCloud.Lexicon`
     never render at all.

  Neither rule is an option, and neither can be relaxed by a caller.

  ## Weighting and stability

  A word's `count` is the number of **distinct submissions** that mention it,
  not its raw repetition count, so a single submitter cannot inflate a word by
  repeating it.

  `level` (1..5) comes from absolute count thresholds rather than a ratio to
  the current maximum. That matters on a projector: with relative sizing every
  word resizes whenever the busiest word gains a mention. With absolute
  thresholds a word only changes size when its own count crosses a threshold.

  Words render in **first-appearance order**, so new words append to the end of
  the cloud and already-visible words keep their position when feedback arrives
  mid-talk.
  """

  alias Notable.WordCloud.Lexicon
  alias Notable.WordCloud.Style

  @min_submissions 2
  @default_max_words 40
  @level_thresholds [2, 3, 5, 8, 13]
  @url_pattern ~r{(?:https?://|www\.)\S+}iu
  @separator_pattern ~r/[^\p{L}\p{N}]+/u
  @letter_pattern ~r/\p{L}/u

  @doc "The number of distinct submissions a word needs before it may render."
  def min_submissions, do: @min_submissions

  @doc "The default cap on how many words are rendered."
  def default_max_words, do: @default_max_words

  @doc """
  Builds the cloud from feedback message bodies.

  `submissions` is one entry per distinct feedback submission, in chronological
  (**oldest-first**) order — that ordering is what makes the rendered layout
  stable. Entries may be `nil` or blank.

  Returns a list of maps in render order, each carrying the word, its count,
  its size `level` (1..5) and the appearance fields added by
  `Notable.WordCloud.Style` — `:tone`, `:tone_class`, `:font_size` and
  `:rotated`.

  ## Options

    * `:max_words` — cap on rendered words (default `#{@default_max_words}`).
  """
  def build(submissions, opts \\ []) when is_list(submissions) do
    max_words = Keyword.get(opts, :max_words, @default_max_words)

    submissions
    |> first_appearances()
    |> tally()
    |> Enum.filter(fn {_word, {count, _pos}} -> count >= @min_submissions end)
    |> take_top(max_words)
    |> Enum.sort_by(fn {_word, {_count, pos}} -> pos end)
    |> Enum.map(fn {word, {count, _pos}} ->
      Style.decorate(%{word: word, count: count, level: level_for(count)})
    end)
  end

  @doc """
  Normalises one message into displayable tokens.

  Case-folds, removes URLs whole (host and path included), strips punctuation,
  and drops pure numbers, single characters, stopwords and blocklisted words.
  Tokens keep their original order and may repeat.
  """
  def tokenize(message) when is_binary(message) do
    message
    |> String.downcase()
    |> String.replace(@url_pattern, " ")
    |> String.split(@separator_pattern, trim: true)
    |> Enum.filter(&displayable?/1)
  end

  def tokenize(_message), do: []

  # One `{word, {submission_index, token_index}}` per word per submission,
  # de-duplicated within a submission so repetition cannot inflate the count.
  defp first_appearances(submissions) do
    submissions
    |> Enum.with_index()
    |> Enum.flat_map(fn {message, submission_index} ->
      message
      |> tokenize()
      |> Enum.with_index()
      |> Enum.uniq_by(fn {word, _token_index} -> word end)
      |> Enum.map(fn {word, token_index} -> {word, {submission_index, token_index}} end)
    end)
  end

  defp tally(appearances) do
    Enum.reduce(appearances, %{}, fn {word, position}, acc ->
      Map.update(acc, word, {1, position}, fn {count, first} -> {count + 1, first} end)
    end)
  end

  # Ranked by submissions desc, then earliest appearance, then alphabetically:
  # fully determined by the input, never by map iteration order.
  defp take_top(entries, max_words) do
    entries
    |> Enum.sort_by(fn {word, {count, pos}} -> {-count, pos, word} end)
    |> Enum.take(max_words)
  end

  defp displayable?(token) do
    String.length(token) > 1 and
      Regex.match?(@letter_pattern, token) and
      not Lexicon.stopword?(token) and
      not Lexicon.blocked?(token)
  end

  defp level_for(count) do
    Enum.count(@level_thresholds, &(&1 <= count))
  end
end
