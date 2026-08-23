defmodule Notable.Wib do
  @moduledoc """
  Fixed Asia/Jakarta (WIB) calendar-day helpers.

  Asia/Jakarta is permanently UTC+07:00 with no DST, so a fixed offset is
  enough. Shared by day-scoped queries (questions board, feedback cloud) so
  the day boundary is defined once.
  """

  @wib_offset_seconds 7 * 3600

  @doc "The Asia/Jakarta date for a UTC `DateTime`."
  def wib_date_of_utc_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.add(@wib_offset_seconds, :second)
    |> DateTime.to_date()
  end

  @doc "Today's Asia/Jakarta date for a UTC `DateTime` (defaults to now)."
  def today_wib(now \\ DateTime.utc_now())
  def today_wib(%DateTime{} = now), do: wib_date_of_utc_datetime(now)
  def today_wib(nil), do: today_wib()

  @doc """
  Half-open UTC `{start, end}` range covering a single WIB day:
  records with `inserted_at >= start and inserted_at < end` belong to that day.
  """
  def wib_date_range(%Date{} = date) do
    start_utc =
      date
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(-@wib_offset_seconds, :second)

    end_utc = DateTime.add(start_utc, 24 * 3600, :second)
    {start_utc, end_utc}
  end
end
