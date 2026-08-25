defmodule Notable.WordCloud.StyleTest do
  use ExUnit.Case, async: true

  alias Notable.WordCloud
  alias Notable.WordCloud.Style

  # A corpus wide enough that "deterministic" and "varied" are both meaningful.
  defp corpus(n \\ 200) do
    for i <- 1..n, do: "kata#{i}"
  end

  describe "tone/1 — colour is a function of the word, never of the count" do
    test "the same word always gets the same tone" do
      for word <- ["materi", "bagus", "praktis", "insightful"] do
        first = Style.tone(word)
        for _ <- 1..20, do: assert(Style.tone(word) == first)
      end
    end

    test "words that share a count still get several different tones" do
      tones = corpus(40) |> Enum.map(&Style.tone/1) |> Enum.uniq()

      assert length(tones) >= 4
    end

    test "every tone it returns is one of the declared tones" do
      declared = Style.tones()

      assert length(declared) >= 5

      for word <- corpus() do
        assert Style.tone(word) in declared
      end
    end

    test "the whole declared palette is reachable" do
      reached = corpus(500) |> Enum.map(&Style.tone/1) |> Enum.uniq() |> Enum.sort()

      assert reached == Enum.sort(Style.tones())
    end

    test "tone_class/1 renders the tone as a stable css class" do
      assert Style.tone_class("materi") == "cloud-tone-#{Style.tone("materi")}"
    end
  end

  describe "size_variation/1 — ragged sizes inside one level" do
    test "the variation of a word never changes" do
      for word <- ["materi", "bagus", "praktis"] do
        first = Style.size_variation(word)
        for _ <- 1..20, do: assert(Style.size_variation(word) == first)
      end
    end

    test "words at the same level do not all get the same variation" do
      variations = corpus(40) |> Enum.map(&Style.size_variation/1) |> Enum.uniq()

      assert length(variations) >= 3
    end

    test "the variation stays inside the declared band" do
      {low, high} = Style.size_variation_range()

      assert low < 1.0
      assert high > 1.0

      for word <- corpus() do
        variation = Style.size_variation(word)
        assert variation >= low
        assert variation <= high
      end
    end
  end

  describe "font_size/2 — count still decides the size band" do
    test "the band never overlaps, so a higher count is always visibly bigger" do
      {low, high} = Style.size_variation_range()

      for level <- 1..4 do
        largest_at_level = Style.base_font_size(level) * high
        smallest_above = Style.base_font_size(level + 1) * low

        assert largest_at_level < smallest_above
      end
    end

    test "font_size/2 is the level's base scaled by the word's own variation" do
      assert_in_delta Style.font_size("materi", 3),
                      Style.base_font_size(3) * Style.size_variation("materi"),
                      0.005
    end

    test "a word's font size does not move when other words gain mentions" do
      quiet = ["materi bagus", "materi jelas"]
      busy = quiet ++ ["praktis keren", "praktis mantap", "praktis rapi", "praktis padat"]

      materi = fn submissions ->
        submissions |> WordCloud.build() |> Enum.find(&(&1.word == "materi"))
      end

      before = materi.(quiet)
      later = materi.(busy)

      assert later.count == before.count
      assert later.level == before.level
      assert later.font_size == before.font_size
    end

    test "two words at the same level get different sizes" do
      sizes = corpus(40) |> Enum.map(&Style.font_size(&1, 1)) |> Enum.uniq()

      assert length(sizes) >= 3
    end
  end

  describe "rotated?/1" do
    test "the same word is always rotated, or always is not" do
      for word <- corpus(20) do
        first = Style.rotated?(word)
        for _ <- 1..10, do: assert(Style.rotated?(word) == first)
      end
    end

    test "a minority of words rotate — enough to notice, not enough to unbalance" do
      rotated = corpus(500) |> Enum.count(&Style.rotated?/1)
      share = rotated / 500

      assert share > 0.1
      assert share < 0.45
    end

    test "rotation is independent of the tone" do
      # If rotation and colour came off the same hash, every rotated word would
      # share a tone.
      tones_of_rotated =
        corpus(500) |> Enum.filter(&Style.rotated?/1) |> Enum.map(&Style.tone/1) |> Enum.uniq()

      assert length(tones_of_rotated) >= 4
    end
  end

  describe "decorate/1" do
    test "adds tone, font size and rotation to a built word without touching the rest" do
      decorated = Style.decorate(%{word: "materi", count: 2, level: 1})

      assert decorated.word == "materi"
      assert decorated.count == 2
      assert decorated.level == 1
      assert decorated.tone == Style.tone("materi")
      assert decorated.tone_class == Style.tone_class("materi")
      assert decorated.font_size == Style.font_size("materi", 1)
      assert decorated.rotated == Style.rotated?("materi")
    end
  end

  describe "the cloud as a whole" do
    test "a room where every word is mentioned exactly twice is not one flat colour" do
      submissions = [
        "materi bagus praktis jelas relevan",
        "materi bagus praktis jelas relevan",
        "santai runtut padat inspiratif seru",
        "santai runtut padat inspiratif seru"
      ]

      built = WordCloud.build(submissions)

      assert Enum.all?(built, &(&1.count == 2))
      assert built |> Enum.map(& &1.tone) |> Enum.uniq() |> length() >= 3
      assert built |> Enum.map(& &1.font_size) |> Enum.uniq() |> length() >= 3
    end
  end
end
