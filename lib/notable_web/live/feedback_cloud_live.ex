defmodule NotableWeb.FeedbackCloudLive do
  @moduledoc """
  A closing-slide display page: everything the audience said, as one image.

  Serves both of Notable's display situations from a single LiveView, exactly
  as the `/qr` and `/qr-overlay` pair does:

  * `/cloud` — full-screen dark page for a projector or screen share.
  * `/cloud-overlay` — transparent, header-less OBS browser source.

  Both routes use `Layouts.app` `variant="overlay"`: the `app` variant
  constrains content to `max-w-5xl` and renders the flash group, which pops a
  reconnect banner over a live talk. The real difference is `live_action`
  driving the surface background — `bg-background` for `/cloud`, transparent
  for `/cloud-overlay`.

  Words come from free feedback message bodies (`Donation` rows with
  `status: "sent"`) for the **current Asia/Jakarta (WIB) day**, ranked by
  `Notable.WordCloud`, which enforces the two display-time safety rules — a
  word needs two distinct submissions, and blocklisted words never render.
  How a word *looks* — its colour, its exact size and whether it stands
  vertical — is decided by `Notable.WordCloud.Style` and rendered onto the
  element as a class, a `font-size` and `data-rotated`. Where a word *sits* is
  decided by the `WordCloud` hook in `assets/js/app.js`, which measures the
  rendered text and packs it. Nothing about appearance is decided in
  JavaScript; nothing about geometry is decided here.

  Without JavaScript, or before the hook mounts, `.cloud-words` is still a
  centred wrapping list, so the page degrades to something readable rather than
  a heap of words at one point.

  Updates arrive on the existing `donations:created` topic, so feedback
  submitted during the closing minutes appears without a refresh. A long-lived
  OBS overlay also rolls at WIB midnight so yesterday's words leave assigns
  and cannot starve tonight's.
  """

  use NotableWeb, :live_view

  alias Notable.Donations
  alias Notable.Qr
  alias Notable.Wib
  alias Notable.WordCloud
  alias NotableWeb.WibClock

  @topic "donations:created"

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    now = WibClock.current_now(session)
    today = Wib.today_wib(now)

    socket =
      socket
      |> WibClock.assign_injected_now(session)
      |> assign(:today, today)
      |> assign(:messages, load_feedback_messages(today))
      |> assign(:public_url, Qr.public_url())
      |> assign_cloud()
      |> assign_meta()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Notable.PubSub, @topic)
      WibClock.schedule_midnight_rollover(socket, today)
    end

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({:donation_created, %{status: "sent"} = feedback}, socket) do
    if current_wib_day?(feedback, socket) do
      {:noreply,
       socket
       |> update(:messages, &(&1 ++ [feedback.message]))
       |> assign_cloud()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:donation_created, _donation}, socket), do: {:noreply, socket}

  def handle_info(:midnight_rollover, socket) do
    today = Wib.today_wib(WibClock.current_now(socket))

    socket =
      socket
      |> assign(:today, today)
      |> assign(:messages, load_feedback_messages(today))
      |> assign_cloud()
      |> WibClock.schedule_midnight_rollover(today)

    {:noreply, socket}
  end

  # Test seam: advance the injectable current-time clock without sleeps so the
  # midnight rollover can be exercised deterministically. Inert in production.
  def handle_info({:set_current_now, %DateTime{} = now}, socket) do
    {:noreply, assign(socket, :current_now, now)}
  end

  # Feedback is stored newest-first; the cloud wants chronological order so
  # first-appearance ranking keeps already-visible words in place.
  defp load_feedback_messages(%Date{} = today) do
    today
    |> Donations.list_feedback_for_date()
    |> Enum.reverse()
    |> Enum.map(& &1.message)
  end

  defp current_wib_day?(%{inserted_at: %DateTime{} = inserted_at}, socket) do
    Wib.wib_date_of_utc_datetime(inserted_at) == socket.assigns.today
  end

  defp current_wib_day?(_feedback, _socket), do: false

  defp assign_cloud(socket) do
    assign(socket, :words, WordCloud.build(socket.assigns.messages))
  end

  defp assign_meta(socket) do
    socket
    |> assign(:page_title, "Suara Ruangan")
    |> assign(:meta_description, "Awan kata dari feedback penonton, ditampilkan langsung.")
    |> assign(:meta_robots, "noindex, nofollow")
    |> assign(:canonical_url, socket.assigns.public_url <> path_for(socket.assigns.live_action))
  end

  defp path_for(:overlay), do: "/cloud-overlay"
  defp path_for(_action), do: "/cloud"

  # Both routes use the layout's bare display variant: full height, no site
  # header, and crucially no flash or reconnect banners, which must never pop
  # over a talk. The only difference is whether the page paints a background.
  defp surface(:overlay), do: "obs"
  defp surface(_action), do: "screen"

  defp surface_class(:overlay), do: nil
  defp surface_class(_action), do: "bg-background"

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant="overlay" show_header={false}>
      <section
        id="feedback-cloud"
        data-surface={surface(@live_action)}
        class={[
          "relative flex min-h-dvh w-full flex-col items-center justify-center overflow-hidden",
          "px-6 py-10 sm:px-12",
          surface_class(@live_action)
        ]}
      >
        <h1 class="sr-only">Suara ruangan: awan kata dari feedback penonton</h1>

        <div
          :if={@words == []}
          id="feedback-cloud-empty"
          class="flex flex-col items-center gap-5 text-center"
        >
          <p class="font-display text-4xl font-bold text-text sm:text-6xl">
            Menunggu suara ruangan…
          </p>
          <p class="max-w-5xl text-2xl font-semibold text-balance text-text-muted sm:text-4xl">
            Kirim feedback di <span class="text-accent">{@public_url}</span>
            dan kata-katamu muncul di sini.
          </p>
        </div>

        <ul
          :if={@words != []}
          id="feedback-cloud-words"
          phx-hook="WordCloud"
          class="cloud-words"
        >
          <li
            :for={word <- @words}
            data-word={word.word}
            data-level={word.level}
            data-rotated={to_string(word.rotated)}
            style={"font-size: #{word.font_size}rem"}
            class={["cloud-word font-display font-bold tracking-tight", word.tone_class]}
          >
            {word.word}<span class="sr-only">, disebut {word.count} kali</span>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
