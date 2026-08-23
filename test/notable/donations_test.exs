defmodule Notable.DonationsTest do
  use Notable.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Notable.Donations
  alias Notable.Donations.Donation
  alias Notable.Repo
  alias Notable.Wib

  describe "create_pending_donation/1" do
    test "creates a pending donation at QR generation time" do
      attrs = %{
        mayar_transaction_id: "tx-1",
        donor_name: "Riza",
        reaction: "great",
        amount: 10_000,
        message: "semangat"
      }

      assert {:ok, %Donation{} = donation} = Donations.create_pending_donation(attrs)
      assert donation.mayar_transaction_id == "tx-1"
      assert donation.donor_name == "Riza"
      assert donation.amount == 10_000
      assert donation.message == "semangat"
      assert donation.status == "pending"
      refute donation.alerted
    end

    test "rejects duplicate mayar_transaction_id values" do
      assert {:ok, %Donation{}} =
               Donations.create_pending_donation(%{
                 mayar_transaction_id: "tx-duplicate",
                 donor_name: "Riza",
                 reaction: "good",
                 amount: 10_000
               })

      assert {:error, changeset} =
               Donations.create_pending_donation(%{
                 mayar_transaction_id: "tx-duplicate",
                 donor_name: "Riza",
                 reaction: "good",
                 amount: 10_000
               })

      assert "has already been taken" in errors_on(changeset).mayar_transaction_id
    end
  end

  describe "create_feedback/1" do
    test "creates an alerted sent note without payment details" do
      assert {:ok, %Donation{} = feedback} =
               Donations.create_feedback(%{
                 donor_name: "Riza",
                 reaction: "great",
                 message: "Stream-nya seru"
               })

      assert feedback.donor_name == "Riza"
      assert feedback.reaction == "great"
      assert feedback.message == "Stream-nya seru"
      assert feedback.status == "sent"
      assert feedback.alerted
      assert is_nil(feedback.mayar_transaction_id)
      assert is_nil(feedback.amount)
    end
  end

  describe "mark_paid_by_mayar_transaction_id/1" do
    test "marks donation paid by mayar transaction id" do
      {:ok, donation} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-2",
          donor_name: "Donor",
          reaction: "good",
          amount: 25_000
        })

      assert donation.status == "pending"

      assert {:ok, %Donation{} = updated} =
               Donations.mark_paid_by_mayar_transaction_id("tx-2")

      assert updated.id == donation.id
      assert updated.status == "paid"
    end

    test "is idempotent for already paid donations" do
      {:ok, donation} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-2b",
          donor_name: "Donor",
          reaction: "good",
          amount: 25_000
        })

      assert {:ok, %Donation{} = updated} =
               Donations.mark_paid_by_mayar_transaction_id("tx-2b")

      assert updated.id == donation.id
      assert updated.status == "paid"

      assert {:ok, %Donation{} = second} =
               Donations.mark_paid_by_mayar_transaction_id("tx-2b")

      assert second.id == donation.id
      assert second.status == "paid"
    end

    test "returns not_found when transaction id does not exist" do
      assert {:error, :not_found} = Donations.mark_paid_by_mayar_transaction_id("tx-missing")
    end

    test "claims paid at most once under concurrent mark_paid calls" do
      {:ok, donation} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-concurrent-claim",
          donor_name: "Donor",
          reaction: "good",
          amount: 25_000
        })

      results =
        1..12
        |> Enum.map(fn _ ->
          Task.async(fn -> Donations.mark_paid_with_change(donation) end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      winners = for {:ok, %Donation{status: "paid"}, true} <- results, do: true
      losers = for {:ok, %Donation{status: "paid"}, false} <- results, do: true

      assert length(winners) == 1
      assert length(losers) == 11
      assert %Donation{status: "paid"} = Repo.get!(Donation, donation.id)
    end
  end

  describe "list_paid_unalerted_donations/0" do
    test "returns only paid and unalerted donations for overlay recovery" do
      {:ok, _pending} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-3",
          donor_name: "A",
          reaction: "bad",
          amount: 10_000
        })

      assert {:ok, %Donation{} = paid_unalerted} =
               Donations.mark_paid_by_mayar_transaction_id("tx-3")

      {:ok, _pending} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-4",
          donor_name: "B",
          reaction: "ok",
          amount: 10_000
        })

      {:ok, _pending} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-5",
          donor_name: "C",
          reaction: "great",
          amount: 10_000
        })

      assert {:ok, %Donation{} = paid} = Donations.mark_paid_by_mayar_transaction_id("tx-5")
      assert {:ok, %Donation{} = _paid_alerted} = Donations.mark_donation_alerted(paid)

      result = Donations.list_paid_unalerted_donations()

      assert Enum.map(result, & &1.id) == [paid_unalerted.id]
    end
  end

  describe "mark_donation_alerted/1" do
    test "marks paid donation as alerted" do
      {:ok, _pending} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-6",
          donor_name: "D",
          reaction: "good",
          amount: 50_000
        })

      assert {:ok, %Donation{} = donation} = Donations.mark_paid_by_mayar_transaction_id("tx-6")
      assert {:ok, %Donation{} = updated} = Donations.mark_donation_alerted(donation)
      assert updated.id == donation.id
      assert updated.alerted
      assert updated.status == "paid"
    end

    test "rejects alerting a pending donation" do
      assert {:ok, %Donation{} = donation} =
               Donations.create_pending_donation(%{
                 mayar_transaction_id: "tx-6b",
                 donor_name: "D",
                 reaction: "good",
                 amount: 50_000
               })

      assert {:error, :invalid_state} = Donations.mark_donation_alerted(donation)
    end

    test "is idempotent for already alerted donations" do
      {:ok, _pending} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-6c",
          donor_name: "D",
          reaction: "good",
          amount: 50_000
        })

      assert {:ok, %Donation{} = donation} = Donations.mark_paid_by_mayar_transaction_id("tx-6c")
      assert {:ok, %Donation{} = alerted} = Donations.mark_donation_alerted(donation)
      assert alerted.alerted

      assert {:ok, %Donation{} = second} = Donations.mark_donation_alerted(alerted)
      assert second.id == alerted.id
      assert second.alerted
    end
  end

  describe "mark_donation_alerted_by_id/1" do
    test "marks paid donation as alerted" do
      {:ok, _pending} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-alerted-by-id-1",
          donor_name: "D",
          reaction: "good",
          amount: 50_000
        })

      assert {:ok, %Donation{} = donation} =
               Donations.mark_paid_by_mayar_transaction_id("tx-alerted-by-id-1")

      assert {:ok, %Donation{} = updated} = Donations.mark_donation_alerted_by_id(donation.id)
      assert updated.alerted
      assert updated.status == "paid"
    end

    test "returns not_found for unknown ids" do
      assert {:error, :not_found} = Donations.mark_donation_alerted_by_id(Ecto.UUID.generate())
    end
  end

  describe "list_donations/1" do
    test "defaults to paid donations" do
      {:ok, _pending} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-list-pending-1",
          donor_name: "Pending Donor",
          reaction: "ok",
          amount: 10_000
        })

      {:ok, paid} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-list-paid-1",
          donor_name: "Paid Donor",
          reaction: "great",
          amount: 20_000
        })

      {:ok, paid, _} = Donations.mark_paid_with_change(paid)

      result = Donations.list_donations()
      assert Enum.map(result, & &1.id) == [paid.id]
    end

    test "lists all, paid, or pending donations based on filter" do
      {:ok, pending} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-list-pending-2",
          donor_name: "Pending Donor",
          reaction: "ok",
          amount: 10_000
        })

      {:ok, paid} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-list-paid-2",
          donor_name: "Paid Donor",
          reaction: "great",
          amount: 20_000
        })

      {:ok, paid, _} = Donations.mark_paid_with_change(paid)

      # Test atom filters
      assert Enum.map(Donations.list_donations(:all), & &1.id) |> Enum.sort() ==
               Enum.sort([pending.id, paid.id])

      assert Enum.map(Donations.list_donations(:paid), & &1.id) == [paid.id]
      assert Enum.map(Donations.list_donations(:pending), & &1.id) == [pending.id]

      # Test string filters
      assert Enum.map(Donations.list_donations("all"), & &1.id) |> Enum.sort() ==
               Enum.sort([pending.id, paid.id])

      assert Enum.map(Donations.list_donations("paid"), & &1.id) == [paid.id]
      assert Enum.map(Donations.list_donations("pending"), & &1.id) == [pending.id]
    end

    test "lists tips as rows with an amount, excluding feedback" do
      {:ok, pending_tip} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-list-tips-pending",
          donor_name: "Pending Tipper",
          reaction: "ok",
          amount: 10_000
        })

      {:ok, paid_tip} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-list-tips-paid",
          donor_name: "Paid Tipper",
          reaction: "great",
          amount: 20_000
        })

      {:ok, paid_tip, _} = Donations.mark_paid_with_change(paid_tip)

      {:ok, feedback} =
        Donations.create_feedback(%{
          donor_name: "Free Sender",
          reaction: "good",
          message: "no tip"
        })

      tip_ids = Enum.map(Donations.list_donations(:tips), & &1.id)
      assert Enum.sort(tip_ids) == Enum.sort([pending_tip.id, paid_tip.id])
      refute feedback.id in tip_ids

      assert Enum.map(Donations.list_donations("tips"), & &1.id) |> Enum.sort() ==
               Enum.sort([pending_tip.id, paid_tip.id])
    end

    test "lists feedback as sent notes, excluding tips" do
      {:ok, pending_tip} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-list-feedback-pending",
          donor_name: "Pending Tipper",
          reaction: "ok",
          amount: 10_000
        })

      {:ok, paid_tip} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-list-feedback-paid",
          donor_name: "Paid Tipper",
          reaction: "great",
          amount: 20_000
        })

      {:ok, paid_tip, _} = Donations.mark_paid_with_change(paid_tip)

      {:ok, feedback} =
        Donations.create_feedback(%{
          donor_name: "Free Sender",
          reaction: "good",
          message: "no tip"
        })

      feedback_ids = Enum.map(Donations.list_donations(:feedback), & &1.id)
      assert feedback_ids == [feedback.id]
      refute pending_tip.id in feedback_ids
      refute paid_tip.id in feedback_ids

      assert Enum.map(Donations.list_donations("feedback"), & &1.id) == [feedback.id]
    end

    test "list_feedback_for_date/1 returns only feedback in the WIB day" do
      today = Wib.today_wib()
      yesterday = Date.add(today, -1)
      {yesterday_start, _} = Wib.wib_date_range(yesterday)
      {today_start, _} = Wib.wib_date_range(today)

      {:ok, prior} =
        Donations.create_feedback(%{
          donor_name: "Prior",
          reaction: "good",
          message: "kemarin"
        })

      {:ok, same_day} =
        Donations.create_feedback(%{
          donor_name: "Today",
          reaction: "good",
          message: "hari ini"
        })

      Repo.update_all(from(d in Donation, where: d.id == ^prior.id),
        set: [inserted_at: DateTime.add(yesterday_start, 3600, :second)]
      )

      Repo.update_all(from(d in Donation, where: d.id == ^same_day.id),
        set: [inserted_at: DateTime.add(today_start, 3600, :second)]
      )

      today_ids = Enum.map(Donations.list_feedback_for_date(today), & &1.id)
      assert today_ids == [same_day.id]
      refute prior.id in today_ids
    end

    test "lists all donations ordered by newest first" do
      {:ok, first} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-7",
          donor_name: "E",
          reaction: "good",
          amount: 15_000
        })

      {:ok, second} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-8",
          donor_name: "F",
          reaction: "great",
          amount: 20_000
        })

      older = ~U[2026-01-01 00:00:00Z]
      newer = ~U[2026-01-02 00:00:00Z]

      Repo.update_all(from(d in Donation, where: d.id == ^first.id),
        set: [inserted_at: older, updated_at: older]
      )

      Repo.update_all(from(d in Donation, where: d.id == ^second.id),
        set: [inserted_at: newer, updated_at: newer]
      )

      result = Donations.list_donations(:all)

      assert Enum.map(result, & &1.id) == [second.id, first.id]
    end
  end

  describe "get_donation_stats/0" do
    test "calculates paid and pending counts and paid sum" do
      {:ok, _pending1} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-stats-1",
          donor_name: "A",
          reaction: "bad",
          amount: 10_000
        })

      {:ok, _paid1} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-stats-2",
          donor_name: "B",
          reaction: "ok",
          amount: 20_000
        })

      {:ok, _paid2} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-stats-3",
          donor_name: "C",
          reaction: "great",
          amount: 30_000
        })

      {:ok, _} = Donations.mark_paid_by_mayar_transaction_id("tx-stats-2")
      {:ok, _} = Donations.mark_paid_by_mayar_transaction_id("tx-stats-3")

      stats = Donations.get_donation_stats()
      assert stats.paid_count == 2
      assert stats.paid_sum == 50_000
      assert stats.pending_count == 1
    end
  end

  describe "claim_pending_by_amount/3" do
    test "atomically claims, remaps transaction id, and marks paid for a unique match" do
      {:ok, donation} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-original-1",
          donor_name: "Maya",
          reaction: "great",
          amount: 15_000
        })

      assert {:ok, claimed, true} =
               Donations.claim_pending_by_amount(15_000, nil, "tx-confirmation-1")

      assert claimed.id == donation.id
      assert claimed.status == "paid"
      assert claimed.mayar_transaction_id == "tx-confirmation-1"

      reloaded = Repo.get!(Donation, donation.id)
      assert reloaded.status == "paid"
      assert reloaded.mayar_transaction_id == "tx-confirmation-1"
    end

    test "fails closed with :ambiguous when multiple pending tips share the same amount" do
      {:ok, _d1} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-amb-1",
          donor_name: "Alice",
          reaction: "good",
          amount: 20_000
        })

      {:ok, _d2} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-amb-2",
          donor_name: "Bob",
          reaction: "great",
          amount: 20_000
        })

      assert {:error, :ambiguous} =
               Donations.claim_pending_by_amount(20_000, nil, "tx-confirmation-amb")

      # Both remain pending — no wrong-tip remap
      assert %Donation{status: "pending", mayar_transaction_id: "tx-amb-1"} =
               Repo.get_by!(Donation, mayar_transaction_id: "tx-amb-1")

      assert %Donation{status: "pending", mayar_transaction_id: "tx-amb-2"} =
               Repo.get_by!(Donation, mayar_transaction_id: "tx-amb-2")
    end

    test "donor_name disambiguates when multiple tips share the same amount" do
      {:ok, _d1} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-dis-1",
          donor_name: "Alice",
          reaction: "good",
          amount: 25_000
        })

      {:ok, d2} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-dis-2",
          donor_name: "Bob",
          reaction: "great",
          amount: 25_000
        })

      assert {:ok, claimed, true} =
               Donations.claim_pending_by_amount(25_000, "Bob", "tx-confirmation-dis")

      assert claimed.id == d2.id
      assert claimed.status == "paid"
      assert claimed.mayar_transaction_id == "tx-confirmation-dis"

      # Alice remains pending
      assert %Donation{status: "pending"} =
               Repo.get_by!(Donation, mayar_transaction_id: "tx-dis-1")
    end

    test "returns :not_found for an orphan payment with no matching pending tip" do
      assert {:error, :not_found} =
               Donations.claim_pending_by_amount(99_999, nil, "tx-orphan")
    end

    test "returns :ambiguous when donor_name matches multiple pending tips" do
      {:ok, _d1} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-same-name-1",
          donor_name: "Alice",
          reaction: "good",
          amount: 30_000
        })

      {:ok, _d2} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-same-name-2",
          donor_name: "Alice",
          reaction: "great",
          amount: 30_000
        })

      assert {:error, :ambiguous} =
               Donations.claim_pending_by_amount(30_000, "Alice", "tx-confirmation-same")
    end

    test "does not claim an already-paid donation" do
      {:ok, _donation} =
        Donations.create_pending_donation(%{
          mayar_transaction_id: "tx-paid-1",
          donor_name: "Maya",
          reaction: "great",
          amount: 40_000
        })

      assert {:ok, _, true} = Donations.claim_pending_by_amount(40_000, nil, "tx-conf-paid")

      # Second claim for the same amount finds nothing pending
      assert {:error, :not_found} =
               Donations.claim_pending_by_amount(40_000, nil, "tx-conf-paid-2")
    end
  end
end
