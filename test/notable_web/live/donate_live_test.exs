defmodule NotableWeb.DonateLiveTest do
  use NotableWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Plug.Test, only: [put_peer_data: 2]

  test "renders the donor form with optional message and collapsed appreciation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#donor-page")
    assert has_element?(view, "#donation-form")
    assert submit_button_count(view) == 1
    assert has_element?(view, "#donation-form button[type='submit']", "Kirim feedback")
    assert has_element?(view, "#donation-form", "Nama kamu")
    assert has_element?(view, "#donation-form", "Pesan (opsional)")
    assert has_element?(view, "#appreciation-toggle")
    assert has_element?(view, "label[for='appreciation-toggle']", "Tambah tip untuk mendukung")
    assert has_element?(view, "label[for='appreciation-toggle']", "Mulai Rp5.000")
    assert has_element?(view, "label[for='appreciation-toggle']", "Bayar praktis dengan QRIS")
    refute has_element?(view, "#amount-options")
    refute has_element?(view, "#donation_form_custom_amount")
  end

  test "disconnected render shows the donor form without claiming visitors", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(id="donation-form")
    refute html =~ ~s(id="visitor-presence-count")
  end

  test "brands the public experience as Notable", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(<title data-default="Notable" data-suffix=" · Notable">)
  end

  test "identifies the Indonesian document language", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(<html lang="id")
  end

  test "renders SEO metadata and structured JSON-LD data", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~
             ~s(<meta name="description" content="Kirim masukan, saran, atau pesan secara gratis. Anda juga dapat memberikan tip apresiasi via QRIS untuk mendukung kreator.")

    assert html =~
             ~s(<meta name="robots" content="index, follow, max-snippet:150, max-image-preview:large")

    assert html =~ ~s(<link rel="canonical" href="http://localhost:4000/")

    assert html =~ ~s(<meta property="og:type" content="website")
    assert html =~ ~s(<meta property="og:title" content="Kirim Feedback &amp; Tips")
    assert html =~ ~s(<meta property="og:site_name" content="Notable")

    # The brand card is 1200x630, so the card type is the large variant rather
    # than the square "summary" this page advertised while it had no image.
    assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")
    assert html =~ ~s(<meta property="og:image" content="http://localhost:4000/og-image.png")
    assert html =~ ~s(<meta property="og:image:width" content="1200")
    assert html =~ ~s(<meta property="og:image:height" content="630")
    assert html =~ ~s(<meta name="twitter:image" content="http://localhost:4000/og-image.png")

    assert html =~ ~s("https://schema.org")
    assert html =~ ~s("Organization")
    assert html =~ ~s("sameAs":)
    assert html =~ ~s("https://rizafahmi.com/")
    assert html =~ ~s("FAQPage")

    # Verify about page link
    assert html =~
             ~s(<a href="https://rizafahmi.com/?utm_source=feedback_app&amp;utm_medium=referral&amp;utm_campaign=donation_page_desc" target="_blank" rel="noopener")
  end

  test "hides amount choices until appreciation is enabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#appreciation-toggle")
    refute has_element?(view, "#amount-options")

    view
    |> form("#donation-form", donation_form: %{"show_appreciation" => "true"})
    |> render_change()

    assert has_element?(view, "#amount-options")
    assert has_element?(view, "#amount-options", "Rp 5.000")
    assert has_element?(view, "#amount-options", "Rp 10.000")
    assert has_element?(view, "#amount-options", "Rp 25.000")
  end

  test "keeps one submit button and updates its copy when appreciation is enabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert submit_button_count(view) == 1
    assert has_element?(view, "#donation-form button[type='submit']", "Kirim feedback")

    view
    |> form("#donation-form", donation_form: %{"show_appreciation" => "true"})
    |> render_change()

    assert submit_button_count(view) == 1

    assert has_element?(
             view,
             "#donation-form button[type='submit']",
             "Kirim feedback + tip"
           )
  end

  test "hides tip UI when appreciation is turned off", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#donation-form", donation_form: %{"show_appreciation" => "true"})
    |> render_change()

    assert has_element?(view, "#amount-options")
    assert submit_button_count(view) == 1

    view
    |> form("#donation-form", donation_form: %{"show_appreciation" => "false"})
    |> render_change()

    refute has_element?(view, "#amount-options")
    assert submit_button_count(view) == 1
    assert has_element?(view, "#donation-form button[type='submit']", "Kirim feedback")
  end

  test "presents feedback-first copy on the default donor path", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "#donor-page h1", donor_hero_headline())
    assert html =~ "Tulis pesan atau masukan secara gratis"
    refute html =~ "Pilih nominal, tulis pesan, lalu bayar via QRIS"
    refute html =~ "Siapkan dukunganmu"
    refute html =~ "QRIS unik untuk setiap donasi"
  end

  test "renders the four approved reaction choices", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#donation_form_reaction_bad[value=bad]")
    assert has_element?(view, "#donation_form_reaction_ok[value=ok]")
    assert has_element?(view, "#donation_form_reaction_good[value=good]")
    assert has_element?(view, "#donation_form_reaction_great[value=great]")
  end

  test "requires a reaction before continuing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#donation-form",
        donation_form: %{
          "donor_name" => "Riza",
          "message" => ""
        }
      )
      |> render_submit()

    assert html =~ "Pilih satu reaksi"
  end

  test "requires a donor name before continuing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#donation-form",
        donation_form: %{
          "donor_name" => "",
          "message" => ""
        }
      )
      |> render_submit()

    assert html =~ "Tulis namamu dulu"
  end

  test "limits donor names to 64 characters", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#donation-form",
        donation_form: %{
          "donor_name" => String.duplicate("a", 65),
          "reaction" => "good",
          "message" => ""
        }
      )
      |> render_submit()

    assert html =~ "Maksimal 64 karakter"
  end

  test "limits optional messages to 280 characters", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#donation-form",
        donation_form: %{
          "donor_name" => "Riza",
          "reaction" => "good",
          "message" => String.duplicate("a", 281)
        }
      )
      |> render_submit()

    assert html =~ "Pesan maksimal 280 karakter"
  end

  test "allows browsers to enter the full 280-character message limit", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#donation_form_message[maxlength='280']")
  end

  test "describes a missing appreciation amount choice as a tip", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#donation-form", donation_form: %{"show_appreciation" => "true"})
    |> render_change()

    html =
      render_submit(view, "submit_feedback", %{
        "donation_form" => %{
          "donor_name" => "Riza",
          "show_appreciation" => "true",
          "amount_option" => "",
          "message" => ""
        }
      })

    assert html =~ "Pilih nominal tip"
    refute html =~ "Pilih nominal donasi"
    assert Notable.Repo.get_by(Notable.Donations.Donation, donor_name: "Riza") == nil
  end

  test "describes a missing custom appreciation amount as a tip", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#donation-form", donation_form: %{"show_appreciation" => "true"})
    |> render_change()

    html =
      render_change(view, "validate", %{
        "donation_form" => %{
          "donor_name" => "Riza",
          "reaction" => "good",
          "show_appreciation" => "true",
          "amount_option" => "custom",
          "message" => "Semangat streamnya"
        }
      })

    assert has_element?(view, "#donation_form_custom_amount")
    assert html =~ ~s(min="1000")
    assert html =~ ~s(step="1000")

    html =
      render_submit(view, "submit_feedback", %{
        "donation_form" => %{
          "donor_name" => "Riza",
          "reaction" => "good",
          "show_appreciation" => "true",
          "amount_option" => "custom",
          "custom_amount" => "",
          "message" => "Semangat streamnya"
        }
      })

    assert html =~ "Masukkan nominal tip"
    refute html =~ "Masukkan nominal donasi"
  end

  test "accepts a valid custom amount", %{conn: conn} do
    # Unique peer IP avoids tip rate-limit collisions with other sync suites that
    # submit tips under LiveViewTest's default 127.0.0.1 peer.
    conn =
      put_peer_data(conn, %{address: {203, 0, 113, 24}, port: 44_326, ssl_cert: nil})

    {:ok, view, _html} = live(conn, ~p"/")

    html =
      render_submit(view, "submit_feedback", %{
        "donation_form" => %{
          "donor_name" => "Riza",
          "reaction" => "good",
          "show_appreciation" => "true",
          "amount_option" => "custom",
          "custom_amount" => "150000",
          "message" => ""
        }
      })

    assert html =~ "QR belum bisa dibuat sekarang"
    refute html =~ "Masukkan nominal donasi"
    refute html =~ "Harus kelipatan 1000"
  end

  test "submits free feedback and shows a thank-you reset state", %{conn: conn} do
    conn =
      put_peer_data(conn, %{address: {203, 0, 113, 20}, port: 44_322, ssl_cert: nil})

    {:ok, view, _html} = live(conn, ~p"/")

    html =
      render_submit(view, "submit_feedback", %{
        "donation_form" => %{
          "donor_name" => "Riza",
          "reaction" => "great",
          "message" => "Stream-nya seru"
        }
      })

    assert html =~ "Terima kasih"
    assert has_element?(view, "#feedback-thanks")
    assert has_element?(view, "#feedback-thanks[role='status'][aria-live='polite']")

    feedback =
      Notable.Repo.get_by!(Notable.Donations.Donation, donor_name: "Riza", status: "sent")

    assert feedback.reaction == "great"
    assert feedback.message == "Stream-nya seru"
    assert is_nil(feedback.amount)
  end

  test "broadcasts accepted free feedback for live admin insert", %{conn: conn} do
    conn =
      put_peer_data(conn, %{address: {203, 0, 113, 21}, port: 44_323, ssl_cert: nil})

    Phoenix.PubSub.subscribe(Notable.PubSub, "donations:created")

    {:ok, view, _html} = live(conn, ~p"/")

    render_submit(view, "submit_feedback", %{
      "donation_form" => %{
        "donor_name" => "Live Admin",
        "reaction" => "good",
        "message" => "halo admin"
      }
    })

    assert_receive {:donation_created, %Notable.Donations.Donation{} = feedback}
    assert feedback.donor_name == "Live Admin"
    assert feedback.status == "sent"
    assert is_nil(feedback.amount)
  end

  test "normal form submit with appreciation enabled uses tip validation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#donation-form", donation_form: %{"show_appreciation" => "true"})
    |> render_change()

    html =
      render_submit(view, "submit_feedback", %{
        "donation_form" => %{
          "donor_name" => "Riza",
          "reaction" => "good",
          "message" => "Apresiasi via tip",
          "show_appreciation" => "true",
          "amount_option" => ""
        }
      })

    assert html =~ "Pilih nominal tip"
    assert has_element?(view, "#donation-form")
    refute has_element?(view, "#feedback-thanks")
    refute has_element?(view, "#payment-expiry")
    assert Notable.Repo.get_by(Notable.Donations.Donation, donor_name: "Riza") == nil
  end

  test "top-level _tip cannot force the tip path when submitted appreciation is false", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      render_submit(view, "submit_feedback", %{
        "_tip" => "1",
        "donation_form" => %{
          "donor_name" => "Crafted Tip",
          "reaction" => "good",
          "message" => "",
          "show_appreciation" => "false",
          "amount_option" => "10000"
        }
      })

    assert has_element?(view, "#feedback-thanks")
    refute has_element?(view, "#payment-expiry")
    refute html =~ "Scan QRIS"

    feedback =
      Notable.Repo.get_by!(Notable.Donations.Donation,
        donor_name: "Crafted Tip",
        status: "sent"
      )

    assert is_nil(feedback.amount)
  end

  test "free submit_feedback on thanks step is a no-op", %{conn: conn} do
    conn =
      put_peer_data(conn, %{address: {203, 0, 113, 23}, port: 44_325, ssl_cert: nil})

    {:ok, view, _html} = live(conn, ~p"/")

    render_submit(view, "submit_feedback", %{
      "donation_form" => %{
        "donor_name" => "Thanks Guard",
        "reaction" => "good",
        "message" => "first"
      }
    })

    assert has_element?(view, "#feedback-thanks")
    before_count = Notable.Repo.aggregate(Notable.Donations.Donation, :count)

    html =
      render_submit(view, "submit_feedback", %{
        "donation_form" => %{
          "donor_name" => "Thanks Guard 2",
          "reaction" => "great",
          "message" => "second should not send"
        }
      })

    assert html =~ "Terima kasih"
    assert has_element?(view, "#feedback-thanks")
    assert Notable.Repo.aggregate(Notable.Donations.Donation, :count) == before_count
    assert Notable.Repo.get_by(Notable.Donations.Donation, donor_name: "Thanks Guard 2") == nil
  end

  defmodule PersistFailingDonations do
    @moduledoc false

    def create_feedback(attrs) do
      changeset =
        %Notable.Donations.Donation{}
        |> Notable.Donations.Donation.changeset(
          Map.merge(%{status: "sent", alerted: true}, attrs)
        )
        |> Ecto.Changeset.add_error(:donor_name, "nama tidak bisa digunakan")
        |> Map.put(:action, :insert)

      {:error, changeset}
    end
  end

  test "free feedback persist changeset errors re-render on form inputs", %{conn: conn} do
    conn =
      put_peer_data(conn, %{address: {203, 0, 113, 33}, port: 44_333, ssl_cert: nil})

    original = Application.get_env(:notable, :donations)

    on_exit(fn ->
      if original do
        Application.put_env(:notable, :donations, original)
      else
        Application.delete_env(:notable, :donations)
      end
    end)

    Application.put_env(:notable, :donations, PersistFailingDonations)

    {:ok, view, _html} = live(conn, ~p"/")

    html =
      render_submit(view, "submit_feedback", %{
        "donation_form" => %{
          "donor_name" => "Persist Fail",
          "reaction" => "good",
          "message" => "should stay on form"
        }
      })

    assert html =~ "Feedback belum bisa dikirim"
    assert html =~ "nama tidak bisa digunakan"
    assert html =~ ~s(value="Persist Fail")
    assert has_element?(view, "#donation-form")
    refute has_element?(view, "#feedback-thanks")
    assert Notable.Repo.get_by(Notable.Donations.Donation, donor_name: "Persist Fail") == nil
  end

  defp submit_button_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#donation-form button[type='submit']")
    |> Enum.count()
  end

  test "links subtly to the Q&A board", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Punya pertanyaan untuk Riza?"
    assert html =~ ~s(href="/questions")
  end
end
