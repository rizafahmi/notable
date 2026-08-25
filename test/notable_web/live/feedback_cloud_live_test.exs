defmodule NotableWeb.FeedbackCloudLiveTest do
  use NotableWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Notable.Donations
  alias Notable.Donations.Donation
  alias Notable.Repo
  alias Notable.Wib
  alias Notable.WordCloud

  defp feedback!(message) do
    {:ok, feedback} =
      Donations.create_feedback(%{
        donor_name: "Penonton",
        reaction: "good",
        message: message
      })

    feedback
  end

  defp set_inserted_at(donation, utc_datetime) do
    {1, _} =
      Repo.update_all(
        from(d in Donation, where: d.id == ^donation.id),
        set: [inserted_at: utc_datetime, updated_at: utc_datetime]
      )

    Repo.get!(Donation, donation.id)
  end

  defp seconds_into_wib_date(%Date{} = date, seconds) when is_integer(seconds) do
    {start_utc, _} = Wib.wib_date_range(date)
    DateTime.add(start_utc, seconds, :second)
  end

  defp cloud_words(view) do
    view
    |> render()
    |> then(&Regex.scan(~r/data-word="([^"]+)"/, &1))
    |> Enum.map(fn [_, word] -> word end)
  end

  # Ten words, every one of them at count 2, so the "equal counts must still
  # look different" rules are actually exercised.
  defp seed_equal_count_cloud! do
    feedback!("materi bagus praktis jelas relevan")
    feedback!("materi bagus praktis jelas relevan")
    feedback!("santai runtut padat inspiratif seru")
    feedback!("santai runtut padat inspiratif seru")
  end

  defp attribute_values(view, pattern) do
    view
    |> render()
    |> then(&Regex.scan(pattern, &1))
    |> Enum.map(fn [_, value] -> value end)
  end

  describe "GET /cloud" do
    test "renders an opaque full-screen dark surface", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cloud")

      assert has_element?(view, "#feedback-cloud[data-surface='screen']")
      assert view |> element("#feedback-cloud") |> render() =~ "bg-background"
    end

    test "renders SEO metadata with noindex robots", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/cloud")

      assert html =~ ~s(<meta name="robots" content="noindex, nofollow")
    end
  end

  describe "GET /cloud-overlay" do
    test "renders a transparent surface that paints no background of its own", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/cloud-overlay")

      assert has_element?(view, "#feedback-cloud[data-surface='obs']")
      assert html =~ "bg-transparent"
      refute view |> element("#feedback-cloud") |> render() =~ "bg-background"
    end

    test "shows the same words as the full-screen page", %{conn: conn} do
      feedback!("materi bagus")
      feedback!("materi jelas")

      {:ok, page, _html} = live(conn, ~p"/cloud")
      {:ok, overlay, _html} = live(conn, ~p"/cloud-overlay")

      assert cloud_words(page) == cloud_words(overlay)
      assert "materi" in cloud_words(overlay)
    end
  end

  describe "display-surface hygiene" do
    # Both routes are projected or captured in front of a room, so neither may
    # carry site chrome or pop a red reconnect banner over the talk.
    for {label, path} <- [{"full-screen", "/cloud"}, {"OBS", "/cloud-overlay"}] do
      test "the #{label} surface shows no header, flash or reconnect banners", %{conn: conn} do
        {:ok, view, _html} = live(conn, unquote(path))

        refute has_element?(view, "header")
        refute has_element?(view, "#flash-group")
        refute has_element?(view, "#client-error")
        refute has_element?(view, "#server-error")
      end

      test "the #{label} surface does not nest a second main element", %{conn: conn} do
        {:ok, _view, html} = live(conn, unquote(path))

        assert length(Regex.scan(~r/<main[\s>]/, html)) == 1
      end
    end
  end

  describe "packed layout" do
    test "the word list is driven by the layout hook, not by flex wrapping", %{conn: conn} do
      seed_equal_count_cloud!()

      {:ok, view, _html} = live(conn, ~p"/cloud")

      assert has_element?(view, "#feedback-cloud-words[phx-hook='WordCloud']")
      refute view |> element("#feedback-cloud-words") |> render() =~ "flex-wrap"
    end

    test "words stay real list items with their word and level attributes", %{conn: conn} do
      seed_equal_count_cloud!()

      {:ok, view, _html} = live(conn, ~p"/cloud")

      assert has_element?(
               view,
               ~s(ul#feedback-cloud-words li[data-word="materi"][data-level="1"])
             )
    end

    test "the hook is handed the words' geometry, never their colour", %{conn: conn} do
      seed_equal_count_cloud!()

      {:ok, view, _html} = live(conn, ~p"/cloud")

      word = view |> element(~s([data-word="materi"])) |> render()

      assert word =~ "font-size:"
      assert word =~ "data-rotated="
    end
  end

  describe "equal counts still look different" do
    test "words with the same count render in several different colours", %{conn: conn} do
      seed_equal_count_cloud!()

      {:ok, view, _html} = live(conn, ~p"/cloud")

      tones = view |> attribute_values(~r/(cloud-tone-\d+)/) |> Enum.uniq()

      assert length(tones) >= 3
    end

    test "words with the same count render at several different sizes", %{conn: conn} do
      seed_equal_count_cloud!()

      {:ok, view, _html} = live(conn, ~p"/cloud")

      sizes = view |> attribute_values(~r/font-size:\s*([\d.]+)rem/) |> Enum.uniq()

      assert length(sizes) >= 3
    end

    test "a deterministic subset of words renders rotated", %{conn: conn} do
      seed_equal_count_cloud!()

      {:ok, view, _html} = live(conn, ~p"/cloud")

      rotations = view |> attribute_values(~r/data-rotated="(\w+)"/) |> Enum.uniq() |> Enum.sort()

      assert rotations == ["false", "true"]
    end

    test "both routes render a word identically", %{conn: conn} do
      seed_equal_count_cloud!()

      {:ok, page, _html} = live(conn, ~p"/cloud")
      {:ok, overlay, _html} = live(conn, ~p"/cloud-overlay")

      assert page |> attribute_values(~r/(cloud-tone-\d+)/) ==
               overlay |> attribute_values(~r/(cloud-tone-\d+)/)

      assert page |> attribute_values(~r/font-size:\s*([\d.]+)rem/) ==
               overlay |> attribute_values(~r/font-size:\s*([\d.]+)rem/)
    end

    test "the smallest cloud — one repeated pair — still shows contrast", %{conn: conn} do
      feedback!("materi bagus")
      feedback!("materi bagus")

      {:ok, view, _html} = live(conn, ~p"/cloud")

      assert cloud_words(view) == ["materi", "bagus"]
      assert view |> attribute_values(~r/(cloud-tone-\d+)/) |> Enum.uniq() |> length() == 2
      assert attribute_values(view, ~r/data-rotated="(\w+)"/) == ["false", "true"]
    end

    test "colour does not move when a word's count grows", %{conn: conn} do
      seed_equal_count_cloud!()

      {:ok, view, _html} = live(conn, ~p"/cloud")

      tone_of = fn v ->
        v
        |> element(~s([data-word="materi"]))
        |> render()
        |> then(&Regex.run(~r/cloud-tone-\d+/, &1))
      end

      before = tone_of.(view)

      for _ <- 1..12, do: broadcast(feedback!("materi lagi"))

      assert tone_of.(view) == before
    end
  end

  describe "surface hygiene for the packed layout" do
    for {label, path} <- [{"full-screen", "/cloud"}, {"OBS", "/cloud-overlay"}] do
      test "the #{label} surface clips its own content so it never scrolls", %{conn: conn} do
        seed_equal_count_cloud!()

        {:ok, view, _html} = live(conn, unquote(path))

        assert view |> element("#feedback-cloud") |> render() =~ "overflow-hidden"
      end
    end
  end

  describe "empty state" do
    test "says something deliberate instead of showing a blank screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cloud")

      assert has_element?(view, "#feedback-cloud-empty")
      assert cloud_words(view) == []
      refute render(view) =~ ~s(data-word=)
    end

    test "the empty state disappears once a word qualifies", %{conn: conn} do
      feedback!("materi bagus")
      feedback!("materi jelas")

      {:ok, view, _html} = live(conn, ~p"/cloud")

      refute has_element?(view, "#feedback-cloud-empty")
    end
  end

  describe "rendered cloud" do
    test "renders words carried by at least two submissions", %{conn: conn} do
      feedback!("materi bagus sekali")
      feedback!("materi sangat bagus")

      {:ok, view, _html} = live(conn, ~p"/cloud")

      words = cloud_words(view)
      assert "materi" in words
      assert "bagus" in words
    end

    test "words are real selectable text in the DOM, not an image or canvas", %{conn: conn} do
      feedback!("materi bagus")
      feedback!("materi jelas")

      {:ok, view, html} = live(conn, ~p"/cloud")

      assert view |> element(~s(#feedback-cloud [data-word="materi"])) |> render() =~ "materi"
      refute html =~ "<canvas"
      refute html =~ "<img"
    end

    test "carries the mention count as text, not by colour or size alone", %{conn: conn} do
      feedback!("materi bagus")
      feedback!("materi jelas")

      {:ok, view, _html} = live(conn, ~p"/cloud")

      word_html = view |> element(~s([data-word="materi"])) |> render()
      assert word_html =~ "2"
      assert word_html =~ "sr-only"
    end
  end

  describe "WIB day scoping" do
    test "previous-day words cannot fill the cap and starve same-day words", %{conn: conn} do
      max_words = WordCloud.default_max_words()
      yesterday = Date.add(Wib.today_wib(), -1)
      prior_words = for i <- 1..max_words, do: "prior#{i}"

      # Fill the cap with higher-count words from a previous WIB day so that,
      # without day scoping, take_top/2 would starve the same-day word at count 2.
      Enum.with_index(prior_words, fn word, index ->
        for offset <- 0..4 do
          word
          |> feedback!()
          |> set_inserted_at(seconds_into_wib_date(yesterday, index * 10 + offset))
        end
      end)

      feedback!("tonightlive")
      feedback!("tonightlive")

      {:ok, view, _html} = live(conn, ~p"/cloud")

      words = cloud_words(view)
      assert "tonightlive" in words
      refute Enum.any?(prior_words, &(&1 in words))
    end
  end

  describe "WIB midnight rollover" do
    test "drops prior-day words so same-day words can surface", %{conn: conn} do
      max_words = WordCloud.default_max_words()
      day = ~D[2026-07-25]
      next_day = Date.add(day, 1)
      before_midnight = DateTime.new!(day, ~T[16:59:00], "Etc/UTC")
      after_midnight = DateTime.new!(day, ~T[17:01:00], "Etc/UTC")
      prior_words = for i <- 1..max_words, do: "prior#{i}"

      Enum.with_index(prior_words, fn word, index ->
        for offset <- 0..4 do
          word
          |> feedback!()
          |> set_inserted_at(seconds_into_wib_date(day, index * 10 + offset))
        end
      end)

      {:ok, view, _html} =
        live_isolated(conn, NotableWeb.FeedbackCloudLive,
          session: %{"current_now" => before_midnight}
        )

      words_before = cloud_words(view)
      assert length(words_before) == max_words
      assert Enum.all?(prior_words, &(&1 in words_before))

      feedback!("tonightlive")
      |> set_inserted_at(seconds_into_wib_date(next_day, 60))

      feedback!("tonightlive")
      |> set_inserted_at(seconds_into_wib_date(next_day, 120))

      send(view.pid, {:set_current_now, after_midnight})
      send(view.pid, :midnight_rollover)

      words = cloud_words(view)
      assert "tonightlive" in words
      refute Enum.any?(prior_words, &(&1 in words))
    end

    test "shows the empty state when the new day has no feedback", %{conn: conn} do
      day = ~D[2026-07-25]
      before_midnight = DateTime.new!(day, ~T[16:59:00], "Etc/UTC")
      after_midnight = DateTime.new!(day, ~T[17:01:00], "Etc/UTC")

      feedback!("materi bagus")
      |> set_inserted_at(seconds_into_wib_date(day, 100))

      feedback!("materi jelas")
      |> set_inserted_at(seconds_into_wib_date(day, 200))

      {:ok, view, _html} =
        live_isolated(conn, NotableWeb.FeedbackCloudLive,
          session: %{"current_now" => before_midnight}
        )

      assert "materi" in cloud_words(view)

      send(view.pid, {:set_current_now, after_midnight})
      send(view.pid, :midnight_rollover)

      assert has_element?(view, "#feedback-cloud-empty")
      assert cloud_words(view) == []
    end
  end

  describe "safety rules in the rendered output" do
    test "a word from a single submission never reaches the screen", %{conn: conn} do
      feedback!("materi bagus")
      feedback!("materi jelas")
      feedback!("kudapannya kurang")

      {:ok, view, _html} = live(conn, ~p"/cloud")

      words = cloud_words(view)
      assert "materi" in words
      refute "kudapannya" in words
      refute render(view) =~ "kudapannya"
    end

    test "a blocklisted word never reaches the screen however many submit it", %{conn: conn} do
      for _ <- 1..6, do: feedback!("anjing materi anjing")

      {:ok, view, _html} = live(conn, ~p"/cloud")

      words = cloud_words(view)
      assert "materi" in words
      refute "anjing" in words
      refute render(view) =~ "anjing"
    end

    test "a blocklisted word arriving live is filtered too", %{conn: conn} do
      feedback!("materi bagus")
      feedback!("materi jelas")

      {:ok, view, _html} = live(conn, ~p"/cloud")

      for _ <- 1..4 do
        broadcast(feedback!("kontol materi"))
      end

      refute render(view) =~ "kontol"
      refute "kontol" in cloud_words(view)
    end
  end

  describe "live updates" do
    test "feedback submitted during the talk appears without a refresh", %{conn: conn} do
      feedback!("materi bagus")
      feedback!("materi jelas")

      {:ok, view, _html} = live(conn, ~p"/cloud")

      refute "praktis" in cloud_words(view)

      broadcast(feedback!("sangat praktis"))
      broadcast(feedback!("praktis dan jelas"))

      assert "praktis" in cloud_words(view)
    end

    test "existing words keep their position when a new word arrives", %{conn: conn} do
      feedback!("materi bagus")
      feedback!("materi bagus")

      {:ok, view, _html} = live(conn, ~p"/cloud")

      before = cloud_words(view)

      broadcast(feedback!("praktis sekali"))
      broadcast(feedback!("praktis juga"))

      updated = cloud_words(view)

      assert Enum.take(updated, length(before)) == before
      assert "praktis" in updated
    end

    test "a paid tip broadcast does not feed the feedback cloud", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cloud")

      {:ok, tip} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-cloud-no-tip",
          donor_name: "Tipper",
          reaction: "great",
          amount: 10_000,
          message: "rahasia tip"
        })

      broadcast(tip)
      broadcast(tip)

      refute render(view) =~ "rahasia"
      assert cloud_words(view) == []
    end
  end

  defp broadcast(donation) do
    Phoenix.PubSub.broadcast(
      Notable.PubSub,
      "donations:created",
      {:donation_created, donation}
    )
  end
end
