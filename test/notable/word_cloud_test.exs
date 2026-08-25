defmodule Notable.WordCloudTest do
  use ExUnit.Case, async: true

  alias Notable.WordCloud

  # `build/2` takes feedback message bodies in chronological (oldest-first)
  # order, one entry per distinct feedback submission.
  defp words(submissions, opts \\ []) do
    submissions |> WordCloud.build(opts) |> Enum.map(& &1.word)
  end

  describe "empty and trivial input" do
    test "no submissions produces no words" do
      assert WordCloud.build([]) == []
    end

    test "submissions with no usable text produce no words" do
      assert WordCloud.build(["", "   ", nil]) == []
    end
  end

  describe "the two-distinct-submissions safety rule" do
    test "a word carried by a single submission never reaches the cloud" do
      assert words(["materi bagus", "materi keren"]) == ["materi"]
    end

    test "repeating a word inside one submission does not make it eligible" do
      assert words(["hebat hebat hebat hebat hebat", "materi lain"]) == []
    end

    test "the minimum is two distinct submissions" do
      assert WordCloud.min_submissions() == 2
    end

    test "weight counts distinct submissions, not raw repetitions" do
      [%{word: "materi", count: count}] =
        WordCloud.build(["materi materi materi", "materi sekali"])

      assert count == 2
    end
  end

  describe "the profanity blocklist" do
    test "a blocklisted word never reaches the cloud however often it is submitted" do
      submissions = List.duplicate("anjing materi anjing", 8)

      assert words(submissions) == ["materi"]
    end

    test "the blocklist covers English as well as Indonesian" do
      refute "fuck" in words(List.duplicate("fuck materi", 5))
    end

    test "the blocklist is populated, so the safety rule is not a no-op" do
      assert Notable.WordCloud.Lexicon.blocklist_size() > 50
    end

    test "blocklisting is exact-token, so it does not swallow innocent words" do
      # "assalamualaikum" contains "ass" but is not profanity.
      assert "assalamualaikum" in words(["assalamualaikum semua", "assalamualaikum pak"])
    end
  end

  describe "normalisation" do
    test "folds case so one word is not counted twice" do
      assert words(["Materi", "MATERI", "materi"]) == ["materi"]
    end

    test "strips punctuation around words" do
      assert words(["Materi!!!, bagus.", "(materi) -- oke?"]) == ["materi"]
    end

    test "drops URLs entirely, including their host and path words" do
      result = words(["cek https://example.com/slides materi", "materi di www.example.com/x"])

      assert result == ["materi"]
    end

    test "drops pure numbers" do
      assert words(["2026 materi", "materi 42"]) == ["materi"]
    end

    test "drops single characters" do
      assert words(["a b materi", "materi c d"]) == ["materi"]
    end
  end

  describe "stopwords" do
    test "removes Indonesian stopwords" do
      submissions = [
        "yang dan di ini itu untuk dengan tidak saya materi",
        "yang dan di ini itu untuk dengan tidak saya materi"
      ]

      assert words(submissions) == ["materi"]
    end

    test "removes English stopwords" do
      assert words(["the and this is for with your talk", "the and this is a talk"]) == ["talk"]
    end

    test "handles mixed Indonesian and English in one submission" do
      submissions = [
        "the materi sangat good dan bermanfaat",
        "materi is good untuk semua"
      ]

      assert words(submissions) == ["materi", "good"]
    end
  end

  describe "ranking, cap and determinism" do
    test "orders selection by frequency and caps the rendered count" do
      submissions = [
        "alpha beta gamma delta",
        "alpha beta gamma delta",
        "alpha beta gamma",
        "alpha beta",
        "alpha"
      ]

      result = WordCloud.build(submissions, max_words: 2)

      assert length(result) == 2
      assert Enum.map(result, & &1.word) |> Enum.sort() == ["alpha", "beta"]
    end

    test "breaks ties deterministically rather than at random" do
      submissions = ["zulu yankee xray", "zulu yankee xray"]

      first = WordCloud.build(submissions)

      for _ <- 1..20 do
        assert WordCloud.build(submissions) == first
      end
    end

    test "assigns a larger weight level to more-mentioned words" do
      submissions = List.duplicate("populer", 12) ++ List.duplicate("jarang", 2)
      by_word = submissions |> WordCloud.build() |> Map.new(&{&1.word, &1.level})

      assert by_word["populer"] > by_word["jarang"]
    end
  end

  describe "layout stability" do
    test "a new submission appends new words without reordering existing ones" do
      before = ["materi bagus", "materi bagus"]
      later = before ++ ["materi bagus praktis", "praktis sekali"]

      existing = words(before)
      updated = words(later)

      assert Enum.take(updated, length(existing)) == existing
      assert "praktis" in updated
    end

    test "a word keeps its weight level while its own count is unchanged" do
      before = ["materi bagus", "materi bagus"]
      later = before ++ ["praktis jelas", "praktis jelas"]

      level_of = fn subs -> subs |> WordCloud.build() |> Map.new(&{&1.word, &1.level}) end

      assert level_of.(before)["materi"] == level_of.(later)["materi"]
    end
  end

  describe "the two-word cloud" do
    test "a single repeated pair renders in two tones and is not entirely vertical" do
      assert [a, b] = WordCloud.build(["materi bagus", "materi bagus"])

      assert a.tone != b.tone
      assert a.rotated != b.rotated
    end

    test "holds for any pair, not just a lucky one" do
      pairs = for i <- 1..60, do: {"kata#{i}", "lain#{i}"}

      for {x, y} <- pairs do
        assert [a, b] = WordCloud.build(["#{x} #{y}", "#{x} #{y}"])
        assert a.tone != b.tone, "#{x} #{y} share tone #{a.tone}"
        assert a.rotated != b.rotated, "#{x} #{y} share an orientation"
      end
    end

    test "an earlier word qualifying later does not restyle the words already shown" do
      before = ["keren sekali", "materi bagus", "materi bagus"]
      later = before ++ ["keren banget"]

      style_of = fn subs ->
        subs
        |> WordCloud.build()
        |> Map.new(&{&1.word, {&1.tone, &1.font_size, &1.rotated}})
      end

      shown = style_of.(before)
      updated = style_of.(later)

      assert Map.keys(shown) == ["bagus", "materi"]
      assert Map.has_key?(updated, "keren")
      assert updated["materi"] == shown["materi"]
      assert updated["bagus"] == shown["bagus"]
    end
  end
end
