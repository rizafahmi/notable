defmodule NotableWeb.QuestionLive do
  use NotableWeb, :live_view

  import Ecto.Changeset, only: [get_field: 2]

  alias Notable.Questions
  alias Notable.Questions.Question
  alias Notable.SubmissionLimiter
  alias NotableWeb.WibClock

  @pubsub Notable.PubSub
  @topic "questions"

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    now = WibClock.current_now(session)
    today = Questions.today_wib(now)
    visitor_id = session["visitor_id"]
    visitor_hash = hash_visitor_id(visitor_id)

    socket =
      socket
      |> WibClock.assign_injected_now(session)
      |> assign(:today, today)
      |> assign(:visitor_id, visitor_id)
      |> assign(:visitor_hash, visitor_hash)
      |> assign(:can_submit, is_binary(visitor_id) and visitor_id != "")
      |> assign(:max_body, Question.max_body())
      |> assign(:form_expanded, true)
      |> assign(:expanded_dates, %{})
      |> assign(:page_title, "Tanya Jawab")
      |> assign(
        :meta_description,
        "Ajukan pertanyaan untuk Riza dan beri upvote anonim. Pertanyaan langsung tampil di papan hari ini."
      )
      |> assign(:meta_robots, "noindex, follow")
      |> assign(:canonical_url, canonical_url("/questions"))
      |> assign_blank_form()
      |> load_board()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @topic)
      WibClock.schedule_midnight_rollover(socket, today)
    end

    {:ok, socket}
  end

  ## Events

  @impl Phoenix.LiveView
  def handle_event("validate", %{"question_form" => params}, socket) do
    changeset =
      %Question{}
      |> Question.create_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("submit", _params, %{assigns: %{can_submit: false}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Sesi belum siap. Muat ulang halaman untuk mengajukan pertanyaan.")
     |> assign_form(Map.put(blank_changeset(), :action, :insert))}
  end

  def handle_event("submit", %{"question_form" => params}, socket) do
    changeset =
      %Question{}
      |> Question.create_changeset(params)
      |> Map.put(:action, :insert)

    if changeset.valid? do
      submit_valid(socket, changeset)
    else
      {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("toggle_vote", %{"id" => id}, socket) do
    case questions().toggle_vote(id, socket.assigns.visitor_id) do
      {:ok, _} ->
        {:noreply, reload_visible(socket, id)}

      {:error, :already_voted} ->
        # Concurrent double-toggle lost the unique-index race; reload so the UI
        # matches the single persisted vote row instead of crashing the LiveView.
        {:noreply, reload_visible(socket, id)}

      {:error, reason} when reason in [:answered, :hidden] ->
        {:noreply, put_flash(socket, :info, vote_closed_message())}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :form_expanded, not socket.assigns.form_expanded)}
  end

  def handle_event("toggle_date", %{"date" => date_str}, socket) do
    {:ok, date} = Date.from_iso8601(date_str)

    if Map.has_key?(socket.assigns.expanded_dates, date) do
      {:noreply, assign(socket, :expanded_dates, Map.delete(socket.assigns.expanded_dates, date))}
    else
      rows = Questions.list_questions_for_date(date, visitor_hash: socket.assigns.visitor_hash)

      {:noreply,
       assign(socket, :expanded_dates, Map.put(socket.assigns.expanded_dates, date, rows))}
    end
  end

  ## PubSub

  @impl Phoenix.LiveView
  def handle_info({:question_created, id}, socket) do
    case Questions.get_question(id) do
      nil ->
        {:noreply, socket}

      question ->
        date = Questions.wib_date_of_utc_datetime(question.inserted_at)

        {:noreply,
         socket
         |> reload_summaries()
         |> reload_date(date)}
    end
  end

  def handle_info({:question_changed, id}, socket) do
    case Questions.get_question(id) do
      nil ->
        {:noreply, socket}

      question ->
        date = Questions.wib_date_of_utc_datetime(question.inserted_at)

        {:noreply,
         socket
         |> reload_summaries()
         |> reload_date(date)}
    end
  end

  def handle_info(:midnight_rollover, socket) do
    new_today = Questions.today_wib(WibClock.current_now(socket))

    socket =
      socket
      |> assign(:today, new_today)
      |> reload_summaries()
      |> reload_today()
      |> WibClock.schedule_midnight_rollover(new_today)

    {:noreply, socket}
  end

  # Test seam: advance the injectable current-time clock without sleeps so the
  # midnight rollover can be exercised deterministically. Inert in production.
  def handle_info({:set_current_now, %DateTime{} = now}, socket) do
    {:noreply, assign(socket, :current_now, now)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} flash_generations={@flash_generations}>
      <section id="questions-page" class="space-y-6">
        <header class="space-y-2">
          <h1
            id="questions-heading"
            class="font-display text-3xl font-semibold tracking-tight text-text sm:text-4xl"
          >
            Tanya Jawab
          </h1>
          <p class="max-w-2xl text-sm leading-6 text-text-muted sm:text-base">
            Ajukan pertanyaan untuk Riza dan beri upvote pada pertanyaan lain. Pertanyaan langsung tampil di papan hari ini.
          </p>
        </header>

        <.question_form
          form={@form}
          can_submit={@can_submit}
          max_body={@max_body}
          expanded?={@form_expanded}
        />

        <.today_board
          today={@today}
          rows={@today_rows}
          visitor_hash={@visitor_hash}
        />

        <.history_board
          summaries={@historical_summaries}
          expanded_dates={@expanded_dates}
          visitor_hash={@visitor_hash}
        />
      </section>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true
  attr :can_submit, :boolean, default: true
  attr :max_body, :integer, default: 500
  attr :expanded?, :boolean, default: true

  defp question_form(assigns) do
    ~H"""
    <section
      id="question-form-section"
      class="rounded-[2.25rem] border border-stroke/60 bg-background/18 shadow-sm shadow-black/25 ring-1 ring-stroke/35 backdrop-blur"
    >
      <button
        id="toggle-question-form"
        type="button"
        class="flex w-full items-center justify-between gap-3 px-5 py-4 text-left sm:px-6"
        phx-click="toggle_form"
        aria-expanded={if @expanded?, do: "true", else: "false"}
        aria-controls="question-form-panel"
      >
        <span class="min-w-0">
          <span class="block text-sm font-semibold text-text sm:text-base">
            Ajukan pertanyaan
          </span>
          <span class="mt-0.5 block text-xs text-text-muted sm:text-sm">
            {if @expanded?,
              do: "Klik untuk menutup formulir",
              else: "Tulis pertanyaan untuk Riza"}
          </span>
        </span>
        <.icon
          name={if @expanded?, do: "hero-chevron-up", else: "hero-chevron-down"}
          class="size-5 shrink-0 text-text-muted"
        />
      </button>

      <div
        :if={@expanded?}
        id="question-form-panel"
        class="border-t border-stroke/50 px-5 py-5 sm:px-6 sm:py-6"
      >
        <.form
          for={@form}
          id="question-form"
          phx-change="validate"
          phx-submit="submit"
          class="space-y-5"
        >
          <div class="space-y-1.5">
            <.input
              field={@form[:body]}
              type="textarea"
              label="Pertanyaan"
              rows="5"
              maxlength={@max_body}
              placeholder="Tulis pertanyaanmu..."
              required
              autofocus
              class="block w-full resize-y rounded-2xl border border-stroke/70 bg-surface/60 px-4 py-3.5 text-base leading-relaxed text-text shadow-inner shadow-black/20 transition placeholder:text-text-muted/60 focus:border-accent/60 focus:ring-4 focus:ring-accent/10 min-h-32"
            />
            <p id="body-counter" class="text-right text-xs text-text-muted" aria-live="polite">
              {body_length(@form)} / {@max_body}
            </p>
          </div>

          <div class="space-y-2 border-t border-stroke/40 pt-4">
            <.input
              field={@form[:name]}
              label="Nama (opsional)"
              placeholder="Kosongkan untuk anonim"
              autocomplete="name"
              maxlength="64"
            />

            <p class="text-xs text-text-muted">
              Nama yang kamu isi akan tampil untuk umum. Jika dikosongkan, ditampilkan sebagai <strong>Anonim</strong>.
            </p>
          </div>

          <.button type="submit" phx-disable-with="Mengirim..." disabled={not @can_submit}>
            Kirim pertanyaan
          </.button>
        </.form>
      </div>
    </section>
    """
  end

  attr :today, :any, required: true
  attr :rows, :list, required: true
  attr :visitor_hash, :any, default: nil

  defp today_board(assigns) do
    ~H"""
    <section id="today-board" aria-labelledby="today-heading" class="space-y-3">
      <div class="flex items-baseline justify-between">
        <h2
          id="today-heading"
          class="text-sm font-semibold uppercase tracking-[0.2em] text-text-muted"
        >
          Hari ini
        </h2>
        <span class="text-xs text-text-muted">{Calendar.strftime(@today, "%d %b %Y")}</span>
      </div>

      <.question_list :if={@rows != []} id="today-list" rows={@rows} visitor_hash={@visitor_hash} />

      <p
        :if={@rows == []}
        id="today-empty"
        class="rounded-2xl border border-stroke/60 bg-background/12 px-4 py-6 text-center text-sm text-text-muted"
      >
        Belum ada pertanyaan hari ini. Jadil yang pertama!
      </p>
    </section>
    """
  end

  attr :summaries, :list, required: true
  attr :expanded_dates, :map, required: true
  attr :visitor_hash, :any, default: nil

  defp history_board(assigns) do
    ~H"""
    <section :if={@summaries != []} id="history-board" class="space-y-3">
      <h2 class="text-sm font-semibold uppercase tracking-[0.2em] text-text-muted">
        Hari sebelumnya
      </h2>

      <div class="space-y-2">
        <.date_group
          :for={summary <- @summaries}
          summary={summary}
          expanded?={Map.has_key?(@expanded_dates, summary.wib_date)}
          rows={@expanded_dates[summary.wib_date]}
          visitor_hash={@visitor_hash}
        />
      </div>
    </section>
    """
  end

  attr :summary, :map, required: true
  attr :expanded?, :boolean, required: true
  attr :rows, :list, default: nil
  attr :visitor_hash, :any, default: nil

  defp date_group(assigns) do
    ~H"""
    <div
      id={"date-group-#{@summary.wib_date}"}
      class="rounded-2xl border border-stroke/60 bg-background/12"
    >
      <button
        type="button"
        class="flex w-full items-center justify-between px-4 py-3 text-left"
        phx-click="toggle_date"
        phx-value-date={@summary.wib_date}
        aria-expanded={if @expanded?, do: "true", else: "false"}
        aria-controls={"date-list-#{@summary.wib_date}"}
      >
        <span class="text-sm font-medium text-text">
          {Calendar.strftime(@summary.wib_date, "%d %b %Y")}
        </span>
        <span class="text-xs text-text-muted">
          {@summary.total} pertanyaan · {@summary.open} terbuka
        </span>
      </button>

      <div
        :if={@expanded?}
        id={"date-list-#{@summary.wib_date}"}
        class="border-t border-stroke/50 px-2 pb-2 pt-3"
      >
        <.question_list
          :if={@rows != nil and @rows != []}
          id={"history-list-#{@summary.wib_date}"}
          rows={@rows}
          visitor_hash={@visitor_hash}
        />
        <p :if={@rows == nil} class="py-4 text-center text-sm text-text-muted">
          Memuat…
        </p>
        <p :if={@rows == []} class="py-4 text-center text-sm text-text-muted">
          Tidak ada pertanyaan.
        </p>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :visitor_hash, :any, default: nil

  defp question_list(assigns) do
    ~H"""
    <ul id={@id} class="space-y-2" role="list">
      <.question_card :for={row <- @rows} row={row} visitor_hash={@visitor_hash} />
    </ul>
    """
  end

  attr :row, :map, required: true
  attr :visitor_hash, :any, default: nil

  defp question_card(assigns) do
    assigns =
      assign(assigns, :answered?, assigns.row.question.status == "answered")

    ~H"""
    <li
      id={"question-#{@row.question.id}"}
      class="rounded-2xl border border-stroke/60 bg-surface/45 px-4 py-3"
      role="listitem"
    >
      <div class="flex items-start gap-3">
        <.vote_control row={@row} answered?={@answered?} visitor_hash={@visitor_hash} />

        <div class="min-w-0 flex-1 space-y-1">
          <p class="text-sm font-semibold text-text">
            {display_name(@row.question.name)}
          </p>
          <p class="break-words text-sm leading-6 text-text">
            {@row.question.body}
          </p>
          <p class="text-xs text-text-muted">
            {wib_timestamp(@row.question.inserted_at)}
            <span
              :if={@answered?}
              class="ml-2 rounded-full bg-accent-2/15 px-2 py-0.5 text-[0.65rem] font-semibold text-accent-2"
            >
              Terjawab
            </span>
          </p>
        </div>
      </div>
    </li>
    """
  end

  attr :row, :map, required: true
  attr :answered?, :boolean, required: true
  attr :visitor_hash, :any, default: nil

  defp vote_control(assigns) do
    voted? = assigns.row.voted == true
    assigns = assign(assigns, :voted?, voted?)

    ~H"""
    <div class="flex shrink-0 flex-col items-center gap-0.5">
      <button
        type="button"
        class={[
          "flex size-9 items-center justify-center rounded-xl border transition motion-safe:active:scale-95",
          if(@voted?,
            do: "border-accent bg-accent text-background",
            else:
              "border-stroke/60 bg-background/30 text-text-muted hover:border-accent/50 hover:text-accent"
          ),
          @answered? && "cursor-not-allowed opacity-50"
        ]}
        phx-click={not @answered? && "toggle_vote"}
        phx-value-id={@row.question.id}
        disabled={@answered?}
        aria-label={vote_label(@row, @voted?)}
        aria-pressed={@voted?}
      >
        <.icon name="hero-chevron-up" class="size-5" />
      </button>
      <span
        id={"vote-count-#{@row.question.id}"}
        class="text-xs font-semibold tabular-nums text-text"
        aria-live="polite"
      >
        {@row.vote_count}
      </span>
    </div>
    """
  end

  ## Helpers

  defp hash_visitor_id(nil), do: nil

  defp hash_visitor_id(visitor_id) when is_binary(visitor_id),
    do: Questions.hash_visitor_id(visitor_id)

  defp blank_changeset do
    %Question{} |> Question.create_changeset(%{})
  end

  defp assign_blank_form(socket), do: assign_form(socket, blank_changeset())

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, as: :question_form))
  end

  defp load_board(socket) do
    socket
    |> reload_summaries()
    |> reload_today()
  end

  defp reload_summaries(socket) do
    summaries = Questions.list_date_summaries()
    today = socket.assigns.today
    historical = Enum.filter(summaries, &(&1.wib_date != today))
    assign(socket, :historical_summaries, historical)
  end

  defp reload_today(socket) do
    rows =
      Questions.list_questions_for_date(socket.assigns.today,
        visitor_hash: socket.assigns.visitor_hash
      )

    assign(socket, :today_rows, rows)
  end

  defp reload_expanded(socket, date) do
    rows = Questions.list_questions_for_date(date, visitor_hash: socket.assigns.visitor_hash)
    assign(socket, :expanded_dates, Map.put(socket.assigns.expanded_dates, date, rows))
  end

  defp reload_date(socket, date) do
    cond do
      date == socket.assigns.today -> reload_today(socket)
      Map.has_key?(socket.assigns.expanded_dates, date) -> reload_expanded(socket, date)
      true -> socket
    end
  end

  defp reload_visible(socket, question_id) do
    case Questions.get_question(question_id) do
      nil -> socket
      question -> reload_date(socket, Questions.wib_date_of_utc_datetime(question.inserted_at))
    end
  end

  defp submit_valid(socket, changeset) do
    key = {:question, socket.assigns.visitor_id}

    with :ok <- SubmissionLimiter.reserve(key),
         {:ok, _question} <- questions().create_question(form_params(changeset)) do
      {:noreply,
       socket
       |> put_flash(:info, "Pertanyaan terkirim!")
       |> assign(:form_expanded, false)
       |> assign_blank_form()
       |> reload_summaries()
       |> reload_today()}
    else
      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> put_flash(:error, "Tunggu sebentar ya, coba lagi dalam beberapa detik.")
         |> assign(:form_expanded, true)
         |> assign_form(changeset)}

      {:error, %Ecto.Changeset{} = error_changeset} ->
        _ = SubmissionLimiter.release(key)

        {:noreply,
         socket
         |> put_flash(:error, "Pertanyaan belum bisa dikirim. Coba lagi.")
         |> assign(:form_expanded, true)
         |> assign_form(Map.put(error_changeset, :action, :insert))}
    end
  end

  defp form_params(changeset) do
    %{"name" => get_field(changeset, :name), "body" => get_field(changeset, :body)}
  end

  defp body_length(form) do
    case form[:body].value do
      nil -> 0
      value when is_binary(value) -> String.length(value)
      value -> to_string(value) |> String.length()
    end
  end

  defp display_name(nil), do: "Anonim"
  defp display_name(name) when is_binary(name), do: name

  defp vote_label(row, true), do: "Batal upvote pertanyaan (#{row.vote_count} upvote)"
  defp vote_label(row, false), do: "Upvote pertanyaan (#{row.vote_count} upvote)"

  defp vote_closed_message, do: "Pertanyaan ini sudah ditutup untuk voting."

  defp questions, do: Application.get_env(:notable, :questions, Questions)

  defp wib_timestamp(utc_datetime) do
    wib = DateTime.add(utc_datetime, 7 * 3600, :second)
    Calendar.strftime(wib, "%H:%M WIB")
  end

  defp canonical_url(path) do
    base =
      Application.get_env(:notable, :app)[:base_url] |> to_string() |> String.trim_trailing("/")

    base <> path
  end
end
