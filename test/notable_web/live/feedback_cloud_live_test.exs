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
