defmodule NotableWeb.WibClock do
  @moduledoc """
  Injectable clock and WIB midnight-rollover scheduling for display LiveViews.

  Production mounts leave the clock unset so reads fall through to
  `DateTime.utc_now/0`. Tests inject a frozen `current_now` via the session
  (and advance it with `{:set_current_now, %DateTime{}}`) so rollover can be
  exercised without sleeping until the real WIB boundary.
  """

  alias Notable.Wib

  @doc "UTC now, or the test-injected `current_now` when present."
  def current_now(%Phoenix.LiveView.Socket{} = socket), do: current_now(socket.assigns)

  def current_now(source) when is_map(source) do
    injected_now(source) || DateTime.utc_now()
  end

  @doc "Test override only; `nil` when the session/assigns did not inject a clock."
  def injected_now(source) when is_map(source) do
    case Map.get(source, :current_now) || Map.get(source, "current_now") do
      %DateTime{} = now -> now
      _ -> nil
    end
  end

  @doc "Pin `current_now` on the socket only when the session injects one."
  def assign_injected_now(socket, session) when is_map(session) do
    case injected_now(session) do
      %DateTime{} = now -> Phoenix.Component.assign(socket, :current_now, now)
      nil -> socket
    end
  end

  @doc "Schedule `:midnight_rollover` for the next WIB day after `today`."
  def schedule_midnight_rollover(socket, %Date{} = today) do
    ms = Wib.ms_until_next_midnight(today, current_now(socket))
    _ = Process.send_after(self(), :midnight_rollover, ms)
    socket
  end
end
