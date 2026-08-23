defmodule NotableWeb.DonateLive do
  use NotableWeb, :live_view

  import Ecto.Changeset

  require Logger

  alias Notable.Donations
  alias Notable.Mayar.Client
  alias Notable.SubmissionLimiter
  alias NotableWeb.DonationPresenter
  alias NotableWeb.Presence

  @visitor_topic "donate:visitors"
  @preset_amounts [5_000, 10_000, 25_000]
  @preset_amount_options Enum.map(@preset_amounts, &Integer.to_string/1)
  @form_fields [
    :donor_name,
    :reaction,
    :amount_option,
    :custom_amount,
    :message,
    :show_appreciation
  ]
  @form_types %{
    donor_name: :string,
    reaction: :string,
    amount_option: :string,
    custom_amount: :integer,
    message: :string,
    show_appreciation: :boolean
  }

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Notable.PubSub, "donations:paid")
      Notable.Analytics.track_page_view("/")
    end

    preset_amounts =
      Enum.map(@preset_amounts, fn amount ->
        option = Integer.to_string(amount)
        {title, hint, recommended?} = preset_amount_copy(amount)

        %{
          value: amount,
          option: option,
          id: amount_option_id(amount),
          formatted: DonationPresenter.format_idr(amount),
          title: title,
          hint: hint,
          recommended?: recommended?
        }
      end)

    socket =
      socket
      |> assign(:preset_amounts, preset_amounts)
      |> assign(:step, :form)
      |> assign(:donation, nil)
      |> assign(:qr, nil)
      |> assign(:tip_submitting, false)
      |> assign(:client_ip, peer_ip(socket))
      |> assign(:visitor_id, session["visitor_id"])
      |> assign(:visitor_count, 0)
      |> assign(:visitor_topic, visitor_topic(session))
      |> assign(:visitor_tracking_active, false)
      |> assign(:page_title, "Kirim Feedback & Tips")
      |> assign(
        :meta_description,
        "Kirim masukan, saran, atau pesan secara gratis. Anda juga dapat memberikan tip apresiasi via QRIS untuk mendukung kreator."
      )
      |> assign(:meta_robots, "index, follow, max-snippet:150, max-image-preview:large")
      |> assign(
        :canonical_url,
        (Application.get_env(:notable, :app)[:base_url] |> String.trim_trailing("/")) <> "/"
      )
      |> assign_blank_form()

    {:ok, track_visitor(socket, session)}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"donation_form" => params}, socket) do
    changeset =
      params
      |> merge_preserved_amount_params(socket.assigns.form.params)
      |> donation_form_changeset()
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:tip_submitting, false)
     |> assign_form(changeset)}
  end

  def handle_event("submit_feedback", _params, %{assigns: %{step: step}} = socket)
      when step != :form do
    {:noreply, socket}
  end

  def handle_event("submit_feedback", _params, %{assigns: %{tip_submitting: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("submit_feedback", %{"donation_form" => params}, socket) do
    if appreciation_on?(params) do
      submit_tip(socket, params)
    else
      changeset = feedback_form_changeset(params)

      if changeset.valid? do
        submit_valid_feedback(socket, changeset)
      else
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
      end
    end
  end

  def handle_event("new_donation", _params, socket) do
    {:noreply, reset_donor_form(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info({:donation_paid, payload}, socket) when is_map(payload) do
    if donation_match?(socket.assigns[:donation], payload) do
      {:noreply, assign(socket, :step, :paid)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: topic, event: "presence_diff"},
        %{assigns: %{visitor_topic: topic, visitor_tracking_active: true}} = socket
      ) do
    {:noreply, assign_visitor_count(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} flash_generations={@flash_generations} show_header={false}>
      <%= if @step == :payment do %>
        <section class="relative isolate overflow-hidden rounded-[2.5rem] border border-stroke/60 bg-surface/45 px-6 py-8 shadow-xl shadow-black/35 sm:px-8">
          <div class="absolute inset-0 bg-linear-to-br from-accent/12 via-transparent to-accent-2/10" />
          <div class="absolute -left-20 top-10 h-56 w-56 rounded-full bg-accent/10 blur-3xl" />
          <div class="absolute -right-24 bottom-0 h-64 w-64 rounded-full bg-accent-2/10 blur-3xl" />

          <div class="relative space-y-3">
            <p class="text-xs font-semibold uppercase tracking-[0.34em] text-text-muted">
              Dukungan Apresiasi
            </p>
            <h1 class="font-display text-3xl font-semibold tracking-tight text-balance text-text sm:text-4xl">
              Scan QRIS untuk Apresiasi
            </h1>
            <p class="inline-flex max-w-xl items-start gap-2 rounded-2xl border border-accent/25 bg-accent/5 px-3.5 py-2.5 text-sm font-medium leading-6 text-text sm:text-base">
              <span class="mt-2 size-1.5 shrink-0 rounded-full bg-accent" aria-hidden="true"></span>
              Buka aplikasi ewallet atau ebanking kesayangan kamu untuk scan QRIS.
            </p>
            <p class="max-w-xl text-sm leading-6 text-text-muted sm:text-base">
              Pesan dan tip Anda akan tersimpan secara otomatis setelah pembayaran sukses (dan akan masuk antrean alert jika acara sedang offline).
            </p>
            <div
              role="status"
              aria-live="polite"
              class="inline-flex items-center gap-2 rounded-full border border-accent/30 bg-accent/5 px-3 py-1.5 text-xs font-semibold text-accent shadow-[0_0_12px_rgba(75,250,165,0.15)]"
            >
              <.icon name="hero-arrow-path" class="size-4 animate-spin" />
              Menunggu konfirmasi pembayaran
              <span class="relative flex size-2 items-center justify-center">
                <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-accent opacity-75"></span>
                <span class="relative inline-flex size-1.5 rounded-full bg-accent"></span>
              </span>
            </div>
            <p
              :if={@qr.expires_at}
              id="payment-expiry"
              class="text-xs font-medium text-text-muted"
            >
              Berlaku sampai {Calendar.strftime(@qr.expires_at, "%d %b %Y %H:%M UTC")}
            </p>
          </div>

          <div class="relative mt-8 grid gap-6 sm:grid-cols-2 sm:items-start">
            <div class="relative rounded-3xl border bg-background/30 p-6 animate-neon-pulse">
              <div class="absolute inset-3 rounded-2xl bg-linear-to-br from-accent/12 via-transparent to-accent-2/10 blur-xl" />
              <img
                src={@qr.qr_image_url}
                alt="Kode QRIS"
                class="relative mx-auto w-full max-w-xs rounded-2xl bg-surface/60 p-4 shadow-sm shadow-black/30 ring-1 ring-stroke/50 motion-safe:transition motion-safe:hover:scale-[1.01]"
              />
            </div>

            <div class="space-y-4">
              <div class="rounded-3xl border border-stroke/60 bg-background/25 px-5 py-5">
                <p class="text-xs font-semibold uppercase tracking-[0.24em] text-text-muted">
                  Ringkasan
                </p>
                <p class="mt-2 text-2xl font-semibold tracking-tight text-text">
                  Rp {DonationPresenter.format_idr(@donation.amount)}
                </p>
                <p class="mt-2 text-sm text-text-muted">
                  Dari {@donation.donor_name}
                </p>
                <p
                  :if={DonationPresenter.present_message?(@donation.message)}
                  class="mt-3 text-sm text-text-muted"
                >
                  "{@donation.message}"
                </p>
              </div>

              <div class="rounded-3xl border border-stroke/60 bg-background/15 px-5 py-5">
                <p class="text-sm font-semibold text-text">Tips biar lancar</p>
                <ul class="mt-3 space-y-2 text-sm text-text-muted">
                  <li class="flex items-start gap-2">
                    <span class="mt-0.5 size-1.5 rounded-full bg-accent/80"></span>
                    Jangan tutup halaman ini sampai status berubah.
                  </li>
                  <li class="flex items-start gap-2">
                    <span class="mt-0.5 size-1.5 rounded-full bg-accent-2/80"></span>
                    Bayar sekali saja untuk QR ini.
                  </li>
                </ul>
              </div>

              <.button
                id="payment-back"
                type="button"
                phx-click="new_donation"
                variant="ghost"
                class="motion-safe:hover:scale-[1.02] motion-safe:active:scale-[0.98]"
              >
                Kembali ke form
              </.button>
            </div>
          </div>
        </section>
      <% else %>
        <%= if @step == :paid do %>
          <section
            role="status"
            aria-live="polite"
            class="relative isolate overflow-hidden rounded-[2.5rem] border bg-surface/45 px-6 py-8 shadow-xl shadow-black/35 sm:px-8 transition-all duration-700 ease-out starting:scale-95 starting:opacity-0 animate-success-glow"
          >
            <div class="absolute inset-0 bg-linear-to-br from-success/14 via-transparent to-accent/10" />
            <div class="absolute -left-16 top-8 h-56 w-56 rounded-full bg-success/10 blur-3xl" />
            <div class="absolute -right-20 bottom-0 h-64 w-64 rounded-full bg-accent/10 blur-3xl" />

            <div class="relative space-y-3">
              <p class="text-xs font-semibold uppercase tracking-[0.34em] text-success">
                Apresiasi Diterima
              </p>
              <h1 class="font-display text-3xl font-semibold tracking-tight text-balance text-text sm:text-4xl">
                Terima kasih! Pesan dan tip Anda telah tersimpan.
              </h1>
              <p class="max-w-xl text-sm leading-6 text-text-muted sm:text-base">
                Dukungan Anda sudah kami terima dan simpan. Pesan Anda akan ditampilkan di layar (atau masuk antrean jika acara sedang offline). Sembari menunggu, yuk baca artikel terbaru atau project saya di <a
                  href="https://rizafahmi.com/?utm_source=feedback_app&utm_medium=referral&utm_campaign=donation_page_thanks_tip"
                  target="_blank"
                  rel="noopener"
                  class="text-accent underline hover:text-accent/80 transition"
                >rizafahmi.com</a>. Terima kasih banyak!
              </p>
            </div>

            <div class="relative mt-8 rounded-3xl border border-stroke/60 bg-background/20 px-5 py-5">
              <p class="text-xs font-semibold uppercase tracking-[0.24em] text-text-muted">
                Ringkasan
              </p>
              <p class="mt-2 text-2xl font-semibold tracking-tight text-text">
                Rp {DonationPresenter.format_idr(@donation.amount)}
              </p>
              <p class="mt-2 text-sm text-text-muted">Dari {@donation.donor_name}</p>
              <p
                :if={DonationPresenter.present_message?(@donation.message)}
                class="mt-3 text-sm text-text-muted"
              >
                "{@donation.message}"
              </p>
            </div>

            <div class="relative mt-6 flex flex-wrap items-center gap-3">
              <.button
                type="button"
                phx-click="new_donation"
                class="motion-safe:hover:scale-[1.02] motion-safe:active:scale-[0.98]"
              >
                Kirim lagi
              </.button>
              <.button
                navigate={~p"/"}
                variant="ghost"
                class="motion-safe:hover:scale-[1.02] motion-safe:active:scale-[0.98]"
              >
                Kembali ke beranda
              </.button>
            </div>
          </section>
        <% else %>
          <%= if @step == :thanks do %>
            <section
              id="feedback-thanks"
              role="status"
              aria-live="polite"
              class="relative isolate overflow-hidden rounded-[2.5rem] border bg-surface/45 px-6 py-8 shadow-xl shadow-black/35 sm:px-8"
            >
              <div class="absolute inset-0 bg-linear-to-br from-accent/12 via-transparent to-accent-2/10" />

              <div class="relative space-y-3">
                <p class="text-xs font-semibold uppercase tracking-[0.34em] text-accent">
                  Pesan Terkirim
                </p>
                <h1 class="font-display text-3xl font-semibold tracking-tight text-balance text-text sm:text-4xl">
                  Terima kasih! Pesan Anda telah kami simpan.
                </h1>
                <p class="max-w-xl text-sm leading-6 text-text-muted sm:text-base">
                  Pesan dan masukan Anda sudah tersimpan dengan aman. Sembari menunggu, yuk baca artikel terbaru atau project saya di <a
                    href="https://rizafahmi.com/?utm_source=feedback_app&utm_medium=referral&utm_campaign=donation_page_thanks_free"
                    target="_blank"
                    rel="noopener"
                    class="text-accent underline hover:text-accent/80 transition"
                  >rizafahmi.com</a>. Terima kasih atas partisipasinya!
                </p>
              </div>

              <div class="relative mt-6 flex flex-wrap items-center gap-3">
                <.button
                  type="button"
                  phx-click="new_donation"
                  class="motion-safe:hover:scale-[1.02] motion-safe:active:scale-[0.98]"
                >
                  Kirim lagi
                </.button>
              </div>
            </section>
          <% else %>
            <% selected_amount_option = selected_amount_option(@form) %>
            <% reaction_error = field_error(@form, :reaction) %>
            <% amount_option_error = field_error(@form, :amount_option) %>

            <section
              id="donor-page"
              class="relative isolate overflow-hidden rounded-[2.75rem] border border-stroke/60 bg-surface/45 shadow-xl shadow-black/35 animate-border-glow"
            >
              <div class="absolute inset-0 bg-linear-to-br from-accent/10 via-transparent to-accent-2/8" />
              <div class="absolute right-0 top-24 h-72 w-72 rounded-full bg-accent/10 blur-3xl" />

              <div class="relative grid gap-8 px-6 py-8 sm:px-8 lg:grid-cols-[0.95fr_1.05fr] lg:px-10 lg:py-10">
                <div class="min-w-0 flex flex-col gap-8">
                  <header class="space-y-4">
                    <div class="inline-flex items-center gap-2 rounded-full border border-accent/35 bg-accent/10 px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.22em] text-accent">
                      <span class="relative flex size-2">
                        <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-accent opacity-75"></span>
                        <span class="relative inline-flex size-2 rounded-full bg-accent"></span>
                      </span>
                      Kotak Masukan Terbuka
                    </div>
                    <p
                      :if={@visitor_count >= 3}
                      id="visitor-presence-count"
                      class="flex items-center gap-2 text-xs font-medium text-text-muted"
                    >
                      <span class="size-1.5 rounded-full bg-accent" aria-hidden="true"></span>
                      {@visitor_count} orang sedang di halaman ini
                    </p>
                    <h1 class="font-display text-4xl font-semibold tracking-tight text-balance text-text sm:text-5xl">
                      Kirim Masukan & Pesan
                    </h1>
                    <p class="max-w-2xl text-sm leading-6 text-text-muted sm:text-base">
                      Tulis pesan atau masukan secara gratis kapan saja untuk mendukung <a
                        href="https://rizafahmi.com/?utm_source=feedback_app&utm_medium=referral&utm_campaign=donation_page_desc"
                        target="_blank"
                        rel="noopener"
                        class="text-accent underline hover:text-accent/80 transition"
                      >Riza Fahmi</a>. Juga bisa menyertakan tip apresiasi via QRIS jika berkenan.
                    </p>
                  </header>

                  <ul class="space-y-4" aria-label="Fitur tersedia">
                    <li class="flex items-start gap-3">
                      <span
                        class="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-xl bg-stroke/60 text-text-muted"
                        aria-hidden="true"
                      >
                        <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" />
                      </span>
                      <div>
                        <p class="text-xs font-semibold uppercase tracking-[0.2em] text-text-muted">
                          Pesan Gratis
                        </p>
                        <p class="mt-0.5 text-sm text-text-muted/80">
                          Kirim masukan atau saran kapan saja, tanpa biaya.
                        </p>
                      </div>
                    </li>
                    <li class="flex items-start gap-3">
                      <span
                        class="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-xl bg-accent-2/15 text-accent-2"
                        aria-hidden="true"
                      >
                        <.icon name="hero-play-circle" class="size-4" />
                      </span>
                      <div>
                        <p class="text-xs font-semibold uppercase tracking-[0.2em] text-accent-2/80">
                          Reaksi Live
                        </p>
                        <p class="mt-0.5 text-sm text-text-muted/80">
                          Emoji reaksi muncul di layar saat acara sedang berlangsung.
                        </p>
                      </div>
                    </li>
                    <li class="flex items-start gap-3">
                      <span
                        class="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-xl bg-accent/15 text-accent"
                        aria-hidden="true"
                      >
                        <.icon name="hero-qr-code" class="size-4" />
                      </span>
                      <div>
                        <p class="text-xs font-semibold uppercase tracking-[0.2em] text-accent">
                          Apresiasi Tip
                        </p>
                        <p class="mt-0.5 text-sm text-text-muted/80">
                          Dukung kreator dengan tip QRIS, opsional.
                        </p>
                      </div>
                    </li>
                  </ul>
                </div>

                <div class="min-w-0 rounded-[2.25rem] border border-stroke/60 bg-background/18 px-5 py-6 shadow-sm shadow-black/25 ring-1 ring-stroke/35 backdrop-blur sm:px-6 sm:py-7">
                  <.form
                    for={@form}
                    id="donation-form"
                    phx-change="validate"
                    phx-submit="submit_feedback"
                    class="space-y-6"
                  >
                    <.input
                      field={@form[:donor_name]}
                      label="Nama kamu"
                      placeholder="Riza"
                      autocomplete="name"
                      autofocus
                      required
                    />

                    <fieldset class="space-y-3">
                      <legend class="text-sm font-semibold text-text">Pilih reaksimu</legend>
                      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
                        <label
                          :for={
                            {reaction, emoji, label} <- [
                              {"bad", "😅", "Bad"},
                              {"ok", "😐", "Okay"},
                              {"good", "😊", "Good"},
                              {"great", "🤩", "Great"}
                            ]
                          }
                          for={"donation_form_reaction_#{reaction}"}
                          class={reaction_classes(to_string(@form[:reaction].value) == reaction)}
                        >
                          <input
                            id={"donation_form_reaction_#{reaction}"}
                            type="radio"
                            name={@form[:reaction].name}
                            value={reaction}
                            checked={@form[:reaction].value == reaction}
                            class="sr-only"
                          />
                          <span class="block text-2xl" aria-hidden="true">{emoji}</span>
                          <span class="mt-1 block">{label}</span>
                        </label>
                      </div>
                      <p :if={reaction_error} class="text-sm font-medium text-danger">
                        {reaction_error}
                      </p>
                    </fieldset>

                    <.input
                      field={@form[:message]}
                      type="textarea"
                      label="Pesan (opsional)"
                      rows="4"
                      maxlength="280"
                      placeholder="Tulis pesan, request lagu, atau kasih semangat..."
                    />

                    <label
                      class={[
                        "group flex cursor-pointer items-center gap-3 rounded-2xl border px-4 py-4 transition-all duration-200 focus-within:ring-4 focus-within:ring-accent-2/20",
                        if(@show_appreciation,
                          do: "border-accent-2/60 bg-accent-2/12 ring-1 ring-accent-2/25",
                          else:
                            "border-accent-2/35 bg-accent-2/6 hover:border-accent-2/55 hover:bg-accent-2/10 active:scale-[0.99]"
                        )
                      ]}
                      for="appreciation-toggle"
                    >
                      <input type="hidden" name={@form[:show_appreciation].name} value="false" />
                      <span
                        class={[
                          "flex size-10 shrink-0 items-center justify-center rounded-xl transition-colors",
                          if(@show_appreciation,
                            do: "bg-accent-2 text-background",
                            else: "bg-accent-2/15 text-accent-2 group-hover:bg-accent-2/20"
                          )
                        ]}
                        aria-hidden="true"
                      >
                        <.icon name="hero-heart" class="size-5" />
                      </span>
                      <span class="min-w-0 flex-1 pointer-events-none select-none">
                        <span class="block text-base font-semibold text-text">
                          Tambah tip untuk mendukung
                        </span>
                        <span class="mt-0.5 block text-xs text-text-muted">
                          Mulai Rp5.000 · Bayar praktis dengan QRIS
                        </span>
                      </span>
                      <span class="flex shrink-0 items-center gap-2">
                        <span class="hidden text-[10px] font-semibold uppercase tracking-[0.12em] text-accent-2 sm:inline">
                          Opsional
                        </span>
                        <input
                          type="checkbox"
                          id="appreciation-toggle"
                          name={@form[:show_appreciation].name}
                          value="true"
                          aria-controls="amount-options"
                          checked={
                            Phoenix.HTML.Form.normalize_value(
                              "checkbox",
                              @form[:show_appreciation].value
                            )
                          }
                          class="sr-only"
                        />
                        <span
                          class={[
                            "flex size-6 items-center justify-center rounded-full border transition-colors",
                            if(@show_appreciation,
                              do: "border-accent-2 bg-accent-2 text-background",
                              else: "border-accent-2/60 bg-background/70 text-transparent"
                            )
                          ]}
                          aria-hidden="true"
                        >
                          <.icon name="hero-check" class="size-4" />
                        </span>
                      </span>
                    </label>

                    <div :if={@show_appreciation} id="amount-options" class="space-y-3">
                      <fieldset class="space-y-3">
                        <legend class="w-full">
                          <span class="flex items-center justify-between gap-3">
                            <span class="text-sm font-semibold text-text">Pilih nominal</span>
                            <span class="text-xs uppercase tracking-[0.2em] text-text-muted">
                              IDR
                            </span>
                          </span>
                        </legend>

                        <div class="grid grid-cols-2 gap-3">
                          <label
                            :for={preset <- @preset_amounts}
                            for={preset.id}
                            class={
                              amount_option_classes(
                                selected_amount_option == preset.option,
                                preset.recommended?
                              )
                            }
                          >
                            <input
                              id={preset.id}
                              type="radio"
                              name={@form[:amount_option].name}
                              value={preset.value}
                              checked={selected_amount_option == preset.option}
                              class="sr-only"
                            />

                            <div class="flex items-start justify-between gap-3">
                              <div class="space-y-1">
                                <span class="block text-sm font-semibold text-text">
                                  {preset.title}
                                </span>
                                <span class="block text-lg font-bold tracking-tight text-text">
                                  Rp {preset.formatted}
                                </span>
                              </div>
                              <span
                                :if={selected_amount_option == preset.option}
                                class="mt-0.5"
                              >
                                <.icon name="hero-check-circle" class="size-5 text-accent" />
                              </span>
                            </div>
                            <span class="text-xs text-text-muted">
                              {preset.hint}
                            </span>
                          </label>

                          <label
                            for="donation_form_amount_option_custom"
                            class={amount_option_classes(selected_amount_option == "custom", false)}
                          >
                            <input
                              id="donation_form_amount_option_custom"
                              type="radio"
                              name={@form[:amount_option].name}
                              value="custom"
                              checked={selected_amount_option == "custom"}
                              class="sr-only"
                            />
                            <div class="space-y-1.5">
                              <span class="text-base font-semibold text-text">Nominal lain</span>
                            </div>
                            <span class="text-xs text-text-muted">Masukkan angka</span>
                          </label>
                        </div>

                        <p :if={amount_option_error} class="text-sm font-medium text-danger">
                          {amount_option_error}
                        </p>
                      </fieldset>

                      <div
                        :if={selected_amount_option == "custom"}
                        class="rounded-3xl border border-stroke/60 bg-background/14 px-4 py-4"
                      >
                        <.input
                          field={@form[:custom_amount]}
                          type="number"
                          label="Nominal custom"
                          placeholder="15000"
                          min="1000"
                          step="1000"
                          required
                        />
                        <div class="mt-2 flex flex-wrap items-center justify-between gap-2 text-xs">
                          <span class="text-text-muted">
                            Masukkan angka tanpa titik atau koma.
                          </span>
                          <span
                            :if={parse_custom_amount(@form[:custom_amount].value) > 0}
                            class="font-semibold text-accent"
                          >
                            Nominal: Rp {DonationPresenter.format_idr(
                              parse_custom_amount(@form[:custom_amount].value)
                            )}
                          </span>
                        </div>
                      </div>
                    </div>

                    <div class="space-y-2.5 pt-1">
                      <button
                        type="submit"
                        disabled={@show_appreciation and @tip_submitting}
                        phx-disable-with={
                          if @show_appreciation, do: "Membuat QR...", else: "Mengirim..."
                        }
                        class="group inline-flex w-full items-center justify-between rounded-3xl bg-accent px-5 py-4 text-left font-semibold text-background shadow-sm shadow-accent/25 ring-1 ring-accent/30 transition duration-200 hover:bg-accent/92 active:bg-accent/88 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent phx-submit-loading:pointer-events-none phx-submit-loading:opacity-70 motion-safe:hover:scale-[1.01] motion-safe:active:scale-[0.99] hover:shadow-lg hover:shadow-accent/30"
                      >
                        <span class="space-y-0.5">
                          <span class="block text-base leading-tight">
                            <%= if @show_appreciation do %>
                              Kirim feedback + tip
                            <% else %>
                              Kirim feedback
                            <% end %>
                          </span>
                          <span class="block text-[11px] font-medium text-background/65 uppercase tracking-[0.12em]">
                            <%= if @show_appreciation do %>
                              Lanjut ke pembayaran QRIS
                            <% else %>
                              Gratis, tanpa tip
                            <% end %>
                          </span>
                        </span>
                        <span class="inline-flex items-center gap-2">
                          <span class="phx-submit-loading:hidden" aria-hidden="true">&rarr;</span>
                          <span class="hidden phx-submit-loading:inline-flex items-center gap-2 text-xs font-semibold">
                            <.icon name="hero-arrow-path" class="size-4 animate-spin" /> Mengirim
                          </span>
                        </span>
                      </button>

                      <p
                        :if={@show_appreciation}
                        class="text-center text-xs text-text-muted/75"
                      >
                        GoPay, OVO, DANA, ShopeePay & semua M-Banking
                      </p>
                    </div>
                  </.form>
                </div>
              </div>
            </section>

            <p class="pt-2 text-center text-xs text-text-muted/70">
              Punya pertanyaan untuk Riza?
              <.link
                navigate={~p"/questions"}
                class="font-medium text-text-muted underline-offset-2 hover:text-accent hover:underline transition"
              >
                Tanya jawab
              </.link>
            </p>
          <% end %>
        <% end %>
      <% end %>

      <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@type": "Organization",
          "name": "Notable",
          "url": "https://feedback.rizafahmi.com",
          "logo": "https://feedback.rizafahmi.com/icon-512.png",
          "sameAs": [
            "https://rizafahmi.com/",
            "https://github.com/rizafahmi",
            "https://twitter.com/rizafahmi"
          ],
          "description": "Notable adalah platform untuk mengirim masukan, saran, atau pesan secara gratis, serta memberikan tip apresiasi via QRIS."
        }
      </script>
      <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@type": "FAQPage",
          "mainEntity": [
            {
              "@type": "Question",
              "name": "Apa itu Notable?",
              "acceptedAnswer": {
                "@type": "Answer",
                "text": "Notable adalah platform untuk mengirim masukan, saran, atau pesan secara gratis, serta memberikan tip apresiasi via QRIS."
              }
            },
            {
              "@type": "Question",
              "name": "Bagaimana cara mengirim pesan secara gratis?",
              "acceptedAnswer": {
                "@type": "Answer",
                "text": "Anda cukup mengisi nama, memilih emoji reaksi, menulis pesan Anda, dan menekan tombol 'Kirim feedback'."
              }
            },
            {
              "@type": "Question",
              "name": "Bagaimana cara memberikan tip apresiasi?",
              "acceptedAnswer": {
                "@type": "Answer",
                "text": "Centang pilihan 'Tambah tip untuk mendukung', pilih nominal tip yang diinginkan, lalu selesaikan pembayaran dengan memindai kode QRIS dinamis yang muncul di layar."
              }
            },
            {
              "@type": "Question",
              "name": "Metode pembayaran apa saja yang didukung untuk tip?",
              "acceptedAnswer": {
                "@type": "Answer",
                "text": "Kami mendukung semua dompet digital (GoPay, OVO, DANA, ShopeePay, LinkAja) serta semua aplikasi M-Banking yang mendukung pembayaran QRIS."
              }
            }
          ]
        }
      </script>
    </Layouts.app>
    """
  end

  defp donation_form_changeset(params, opts \\ []) do
    validate_required? = Keyword.get(opts, :validate_required?, true)

    {%{}, @form_types}
    |> cast(params, @form_fields)
    |> update_change(:donor_name, &trim/1)
    |> maybe_validate_required(validate_required?)
  end

  defp feedback_form_changeset(params) do
    {%{}, Map.take(@form_types, [:donor_name, :reaction, :message])}
    |> cast(params, [:donor_name, :reaction, :message])
    |> update_change(:donor_name, &trim/1)
    |> update_change(:message, &trim/1)
    |> validate_required([:donor_name], message: "Tulis namamu dulu")
    |> validate_required([:reaction], message: "Pilih satu reaksi")
    |> validate_length(:donor_name, max: 64, message: "Maksimal 64 karakter")
    |> validate_length(:message, max: 280, message: "Pesan maksimal 280 karakter")
    |> validate_inclusion(:reaction, ~w(bad ok good great), message: "Pilih satu reaksi")
  end

  defp maybe_validate_required(changeset, false), do: changeset

  defp maybe_validate_required(changeset, true) do
    changeset
    |> validate_required([:donor_name], message: "Tulis namamu dulu")
    |> validate_required([:reaction], message: "Pilih satu reaksi")
    |> validate_length(:donor_name, max: 64, message: "Maksimal 64 karakter")
    |> validate_amount()
    |> validate_length(:message, max: 280, message: "Pesan maksimal 280 karakter")
  end

  defp validate_amount(changeset) do
    case get_field(changeset, :amount_option) do
      option when option in @preset_amount_options ->
        changeset

      "custom" ->
        changeset
        |> validate_required([:custom_amount], message: "Masukkan nominal tip")
        |> validate_number(:custom_amount,
          greater_than_or_equal_to: 1_000,
          message: "Minimal 1000"
        )
        |> validate_change(:custom_amount, fn :custom_amount, amount ->
          validate_custom_amount_step(amount)
        end)

      _ ->
        add_error(changeset, :amount_option, "Pilih nominal tip")
    end
  end

  defp validate_custom_amount_step(amount)
       when is_integer(amount) and rem(amount, 1_000) == 0,
       do: []

  defp validate_custom_amount_step(_amount),
    do: [custom_amount: "Harus kelipatan 1000"]

  defp assign_form(socket, changeset) do
    socket
    |> assign(:form, to_form(changeset, as: :donation_form))
    |> assign(:show_appreciation, show_appreciation?(changeset))
  end

  defp assign_blank_form(socket) do
    assign_form(
      socket,
      donation_form_changeset(
        %{"amount_option" => "10000", "show_appreciation" => false},
        validate_required?: false
      )
    )
  end

  defp reset_donor_form(socket) do
    socket
    |> assign(:step, :form)
    |> assign(:donation, nil)
    |> assign(:qr, nil)
    |> assign(:tip_submitting, false)
    |> assign_blank_form()
  end

  defp show_appreciation?(changeset), do: get_field(changeset, :show_appreciation) == true

  defp appreciation_on?(params) when is_map(params) do
    case Map.get(params, "show_appreciation") do
      value when value in [true, "true", "on", "1"] -> true
      _ -> false
    end
  end

  defp submit_tip(socket, form_params) do
    changeset =
      form_params
      |> merge_preserved_amount_params(socket.assigns.form.params)
      |> put_tip_appreciation()
      |> donation_form_changeset()

    socket = assign(socket, :tip_submitting, true)

    if changeset.valid? do
      # Keep :tip_submitting sticky across create (success and Mayar/DB errors) so a
      # queued second tip event no-ops. Cleared on validate / invalid changeset / reset.
      create_tip_or_assign_error(socket, changeset)
    else
      {:noreply,
       socket
       |> assign(:tip_submitting, false)
       |> assign_form(Map.put(changeset, :action, :insert))}
    end
  end

  defp create_tip_or_assign_error(socket, changeset) do
    client_ip = socket.assigns.client_ip

    case reserve_tip_rate_limit(client_ip) do
      :ok ->
        create_tip_after_rate_limit(socket, changeset)

      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> assign(:tip_submitting, false)
         |> put_flash(:error, "Tunggu sebentar ya, coba lagi dalam beberapa detik.")
         |> assign_form(Map.put(changeset, :action, :validate))}
    end
  end

  defp create_tip_after_rate_limit(socket, changeset) do
    # Reservation is kept whether Mayar/persist succeeds or fails so the same IP
    # cannot spam Mayar create_qr (and orphan QRIS) within the cooldown window.
    case create_pending_donation_with_qr(changeset) do
      {:ok, donation, qr} ->
        {:noreply,
         socket
         |> assign(:step, :payment)
         |> assign(:donation, donation)
         |> assign(:qr, qr)
         |> maybe_reconcile_paid_donation()}

      {:error, :mayar, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, qr_error_message(reason))
         |> assign_form(changeset)}

      {:error, :donation, donation_changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, donation_persist_error_message())
         |> assign_form(copy_changeset_errors(changeset, donation_changeset))}
    end
  end

  defp merge_preserved_amount_params(params, prior) when is_map(prior) do
    params
    |> maybe_preserve_param("amount_option", prior, "10000")
    |> maybe_preserve_param("custom_amount", prior, nil)
  end

  defp maybe_preserve_param(params, key, prior, default) do
    if Map.has_key?(params, key) do
      params
    else
      case Map.fetch(prior, key) do
        {:ok, value} -> Map.put(params, key, value)
        :error when is_binary(default) -> Map.put(params, key, default)
        :error -> params
      end
    end
  end

  defp peer_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} when is_tuple(address) -> address
      _ -> nil
    end
  end

  defp reserve_feedback_rate_limit(nil), do: :ok
  defp reserve_feedback_rate_limit(ip), do: SubmissionLimiter.reserve({:feedback, ip})

  defp release_feedback_rate_limit(nil), do: :ok
  defp release_feedback_rate_limit(ip), do: SubmissionLimiter.release({:feedback, ip})

  defp reserve_tip_rate_limit(nil), do: :ok
  defp reserve_tip_rate_limit(ip), do: SubmissionLimiter.reserve({:tip, ip})

  defp submit_valid_feedback(socket, changeset) do
    client_ip = socket.assigns.client_ip

    with :ok <- reserve_feedback_rate_limit(client_ip),
         {:ok, feedback} <- donations().create_feedback(feedback_attrs(changeset)) do
      broadcast_donation_created(feedback)

      {:noreply,
       socket
       |> assign(:step, :thanks)
       |> assign_blank_form()}
    else
      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> put_flash(:error, "Tunggu sebentar ya, coba lagi dalam beberapa detik.")
         |> assign_form(Map.put(changeset, :action, :validate))}

      {:error, %Ecto.Changeset{} = error_changeset} ->
        release_feedback_rate_limit(client_ip)

        {:noreply,
         socket
         |> put_flash(:error, "Feedback belum bisa dikirim. Coba lagi.")
         |> assign_form(copy_changeset_errors(changeset, error_changeset))}
    end
  end

  # Persist/constraint errors come back on the schema changeset; copy overlapping
  # field errors onto the LiveView form changeset so shared `<.input>`s render them.
  defp copy_changeset_errors(form_changeset, error_changeset) do
    error_changeset.errors
    |> Enum.reduce(form_changeset, fn {field, {msg, opts}}, cs ->
      if Map.has_key?(form_changeset.types, field) do
        add_error(cs, field, msg, opts)
      else
        cs
      end
    end)
    |> Map.put(:action, :insert)
  end

  defp donations, do: Application.get_env(:notable, :donations, Donations)

  defp broadcast_donation_created(donation) do
    Phoenix.PubSub.broadcast(
      Notable.PubSub,
      "donations:created",
      {:donation_created, donation}
    )
  end

  # Keep appreciation on after tip validation errors so amount errors remain visible.
  defp put_tip_appreciation(params) when is_map(params),
    do: Map.put(params, "show_appreciation", true)

  defp feedback_attrs(changeset) do
    %{
      donor_name: get_field(changeset, :donor_name),
      reaction: get_field(changeset, :reaction),
      message: blank_to_nil(get_field(changeset, :message))
    }
  end

  defp selected_amount_option(form), do: form[:amount_option].value

  defp field_error(form, field) do
    case form[field].errors do
      [{message, _opts} | _rest] -> message
      _ -> nil
    end
  end

  defp amount_option_id(amount), do: "donation_form_amount_option_#{amount}"

  defp preset_amount_copy(5_000), do: {"Pemantik chat", "Buka dukungan", false}
  defp preset_amount_copy(10_000), do: {"Naikkan energi", "Paling sering dipilih", true}
  defp preset_amount_copy(25_000), do: {"Masuk spotlight", "Support maksimal", false}

  defp preset_amount_copy(_amount), do: {"Support", "Terima kasih", false}

  defp reaction_classes(selected?)

  defp reaction_classes(true) do
    [
      "group cursor-pointer rounded-2xl border px-3 py-4 text-center text-sm font-semibold text-text transition-all duration-200",
      "scale-[1.02] border-accent/50 bg-linear-to-br from-accent/16 to-accent-2/12 shadow-md shadow-accent/25 ring-1 ring-accent/30 active:scale-100 focus-within:ring-4 focus-within:ring-accent/20 focus-within:border-accent/40"
    ]
  end

  defp reaction_classes(false) do
    [
      "group cursor-pointer rounded-2xl border px-3 py-4 text-center text-sm font-semibold text-text transition-all duration-200",
      "border-stroke/60 bg-background/20 hover:border-accent/35 hover:bg-background/25 active:scale-[0.99] focus-within:ring-4 focus-within:ring-accent/20 focus-within:border-accent/40"
    ]
  end

  defp amount_option_classes(selected?, recommended?)

  defp amount_option_classes(true, _recommended?) do
    [
      "group relative flex min-h-28 cursor-pointer flex-col justify-between overflow-hidden rounded-3xl border px-4 py-4 transition-all duration-200 outline-none",
      "scale-[1.02] border-accent/50 bg-linear-to-br from-accent/16 via-background/12 to-accent-2/12 shadow-md shadow-accent/25 ring-1 ring-accent/30 active:scale-100 focus-within:ring-4 focus-within:ring-accent/20 focus-within:border-accent/40"
    ]
  end

  defp amount_option_classes(false, true) do
    [
      "group relative flex min-h-28 cursor-pointer flex-col justify-between overflow-hidden rounded-3xl border px-4 py-4 transition-all duration-200 outline-none",
      "border-stroke/60 bg-background/14 ring-1 ring-accent/10 hover:border-accent/35 hover:bg-background/18 active:scale-[0.99] focus-within:ring-4 focus-within:ring-accent/20 focus-within:border-accent/40"
    ]
  end

  defp amount_option_classes(false, false) do
    [
      "group relative flex min-h-28 cursor-pointer flex-col justify-between overflow-hidden rounded-3xl border px-4 py-4 transition-all duration-200 outline-none",
      "border-stroke/60 bg-background/14 hover:border-stroke hover:bg-background/18 active:scale-[0.99] focus-within:ring-4 focus-within:ring-accent/20 focus-within:border-accent/40"
    ]
  end

  defp parse_custom_amount(nil), do: 0
  defp parse_custom_amount(""), do: 0
  defp parse_custom_amount(val) when is_integer(val), do: val

  defp parse_custom_amount(val) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> 0
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp track_visitor(socket, session) do
    if connected?(socket) do
      topic = socket.assigns.visitor_topic
      Phoenix.PubSub.subscribe(Notable.PubSub, topic)

      case track_presence(topic, session["visitor_id"]) do
        {:ok, _ref} ->
          socket
          |> assign(:visitor_tracking_active, true)
          |> assign_visitor_count()

        {:error, reason} ->
          fail_visitor_tracking(socket, reason)
      end
    else
      socket
    end
  end

  defp track_presence(topic, visitor_id) when is_binary(visitor_id) and visitor_id != "" do
    presence_mod().track(self(), topic, visitor_id, %{})
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp track_presence(_topic, _visitor_id), do: {:error, :missing_visitor_id}

  defp assign_visitor_count(socket) do
    case list_presence(socket.assigns.visitor_topic) do
      {:ok, presences} ->
        assign(socket, :visitor_count, map_size(presences))

      {:error, reason} ->
        fail_visitor_tracking(socket, reason)
    end
  end

  defp list_presence(topic) do
    {:ok, presence_mod().list(topic)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp fail_visitor_tracking(socket, reason) do
    Logger.warning("Visitor presence tracking failed: #{inspect(reason)}")
    topic = socket.assigns.visitor_topic

    if socket.assigns.visitor_tracking_active do
      _ = untrack_presence(topic, socket.assigns.visitor_id)
    end

    _ = Phoenix.PubSub.unsubscribe(Notable.PubSub, topic)

    socket
    |> assign(:visitor_tracking_active, false)
    |> assign(:visitor_count, 0)
  end

  defp untrack_presence(topic, visitor_id) when is_binary(visitor_id) and visitor_id != "" do
    presence_mod().untrack(self(), topic, visitor_id)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp untrack_presence(_topic, _visitor_id), do: :ok

  defp presence_mod do
    Application.get_env(:notable, :visitor_presence, Presence)
  end

  defp visitor_topic(%{"visitor_presence_topic" => topic})
       when is_binary(topic) and topic != "",
       do: topic

  defp visitor_topic(_session), do: @visitor_topic

  defp create_pending_donation_with_qr(changeset) do
    donor_name = get_field(changeset, :donor_name)
    reaction = get_field(changeset, :reaction)
    amount = donation_amount(changeset)
    message = blank_to_nil(get_field(changeset, :message))

    with {:ok, %Client.DynamicQr{} = qr} <- Client.create_qr(amount),
         {:ok, donation} <-
           create_pending_donation_from_qr(qr, %{
             donor_name: donor_name,
             reaction: reaction,
             amount: amount,
             message: message
           }) do
      {:ok, donation, qr}
    else
      {:error, %Ecto.Changeset{} = donation_changeset, %Client.DynamicQr{} = qr} ->
        log_failed_donation_persist(qr, amount, donation_changeset)
        {:error, :donation, donation_changeset}

      {:error, reason} ->
        {:error, :mayar, reason}
    end
  end

  defp create_pending_donation_from_qr(%Client.DynamicQr{} = qr, %{
         donor_name: donor_name,
         reaction: reaction,
         amount: amount,
         message: message
       }) do
    case donations().create_pending_donation(%{
           mayar_transaction_id: qr.mayar_transaction_id,
           donor_name: donor_name,
           reaction: reaction,
           amount: amount,
           message: message
         }) do
      {:ok, donation} ->
        Logger.info(
          "Pending donation created donation_id=#{donation.id} mayar_transaction_id=#{donation.mayar_transaction_id} amount=#{donation.amount}"
        )

        broadcast_donation_created(donation)

        {:ok, donation}

      {:error, %Ecto.Changeset{} = donation_changeset} ->
        {:error, donation_changeset, qr}
    end
  end

  defp donation_amount(changeset) do
    case get_field(changeset, :amount_option) do
      option when option in @preset_amount_options -> String.to_integer(option)
      "custom" -> get_field(changeset, :custom_amount)
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp maybe_reconcile_paid_donation(%{assigns: %{step: :payment, donation: %{id: id}}} = socket) do
    case Donations.get_donation(id) do
      %{status: "paid"} -> assign(socket, :step, :paid)
      _ -> socket
    end
  end

  defp maybe_reconcile_paid_donation(socket), do: socket

  defp donation_match?(%{id: id}, %{id: payload_id}) when is_binary(id) and is_binary(payload_id),
    do: id == payload_id

  defp donation_match?(%{mayar_transaction_id: tx}, %{mayar_transaction_id: payload_tx})
       when is_binary(tx) and is_binary(payload_tx),
       do: tx == payload_tx

  defp donation_match?(_donation, _payload), do: false

  defp qr_error_message(reason) do
    base_message = "QR belum bisa dibuat sekarang. Coba lagi ya."

    if show_mayar_error_reason?() do
      "#{base_message} (#{mayar_reason(reason)})"
    else
      base_message
    end
  end

  defp show_mayar_error_reason? do
    Application.get_env(:notable, :show_mayar_error_reason, false)
  end

  defp mayar_reason({:unexpected_response, _body}), do: "unexpected_response"
  defp mayar_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp mayar_reason(reason), do: inspect(reason)

  defp changeset_error_summary(%Ecto.Changeset{errors: errors}) when is_list(errors) do
    Enum.map(errors, fn
      {field, {message, _opts}} -> {field, message}
      other -> other
    end)
  end

  defp donation_persist_error_message do
    "Tip belum bisa disimpan. Coba lagi ya. Kalau kamu sudah sempat scan QR, jangan lanjutkan pembayarannya."
  end

  defp log_failed_donation_persist(%Client.DynamicQr{} = qr, amount, donation_changeset) do
    Logger.warning(
      "Could not persist pending donation mayar_transaction_id=#{qr.mayar_transaction_id} amount=#{amount} errors=#{inspect(changeset_error_summary(donation_changeset))}"
    )
  end
end
