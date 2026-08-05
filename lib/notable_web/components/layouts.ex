defmodule NotableWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use NotableWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash} flash_generations={@flash_generations}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :flash_generations, :map, default: %{}

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :variant, :string, values: ~w(app overlay), default: "app"
  attr :show_header, :boolean, default: true

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class={[
      "relative min-h-dvh",
      @variant == "app" && "bg-background",
      @variant == "overlay" && "bg-transparent"
    ]}>
      <div :if={@variant == "app"} class="pointer-events-none absolute inset-0 overflow-hidden">
        <div class="absolute -top-40 left-1/3 h-[32rem] w-[32rem] rounded-full bg-accent/18 blur-3xl" />
        <div class="absolute -bottom-44 right-1/4 h-[34rem] w-[34rem] rounded-full bg-accent-2/14 blur-3xl" />
        <div class="absolute inset-0 bg-linear-to-b from-transparent via-transparent to-black/25" />
      </div>

      <header
        :if={@variant == "app" && @show_header}
        class="sticky top-0 z-30 border-b border-stroke/60 bg-background/70 backdrop-blur"
      >
        <div class="mx-auto flex max-w-5xl items-center justify-between px-4 py-3 sm:px-6">
          <a href="/" class="group flex items-baseline gap-3">
            <span class="font-display text-lg tracking-tight text-text">Notable</span>
            <span class="text-[0.65rem] font-semibold tracking-[0.28em] text-text-muted/80">
              BERI MASUKAN DAN APRESIASI
            </span>
          </a>

          <nav class="flex items-center gap-2">
            <a
              href="https://rizafahmi.com/?utm_source=feedback_app&utm_medium=referral&utm_campaign=donation_page_header"
              target="_blank"
              rel="noopener"
              class="rounded-full border border-stroke/60 bg-surface/60 px-3 py-1.5 text-xs font-semibold text-text-muted transition hover:border-stroke hover:text-text"
            >
              Tentang Riza
            </a>
            <.link
              navigate={~p"/"}
              class="rounded-full border border-stroke/60 bg-surface/60 px-3 py-1.5 text-xs font-semibold text-text-muted transition hover:border-stroke hover:text-text"
            >
              Feedback
            </.link>
            <.link
              navigate={~p"/questions"}
              class="rounded-full border border-stroke/60 bg-surface/60 px-3 py-1.5 text-xs font-semibold text-text-muted transition hover:border-stroke hover:text-text"
            >
              Q&A
            </.link>
            <.link
              navigate={~p"/admin"}
              class="rounded-full border border-stroke/60 bg-surface/60 px-3 py-1.5 text-xs font-semibold text-text-muted transition hover:border-stroke hover:text-text"
            >
              Admin
            </.link>
          </nav>
        </div>
      </header>

      <main class={[
        "relative",
        @variant == "app" && "mx-auto max-w-5xl px-4 py-10 sm:px-6 sm:py-14",
        @variant == "overlay" && "min-h-dvh"
      ]}>
        <div class={[@variant == "app" && "space-y-6"]}>
          {render_slot(@inner_block)}
        </div>
      </main>

      <.flash_group
        :if={@variant == "app"}
        flash={@flash}
        flash_generations={@flash_generations}
      />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} flash_generations={@flash_generations} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :flash_generations, :map,
    required: true,
    doc: "per-kind counters used to reset auto-hide timers"

  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="fixed right-4 top-4 z-50 flex w-[calc(100vw-2rem)] max-w-sm flex-col gap-3"
    >
      <.flash
        kind={:info}
        flash={@flash}
        flash_generation={@flash_generations["info"]}
      />
      <.flash
        kind={:error}
        flash={@flash}
        flash_generation={@flash_generations["error"]}
      />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        auto_hide={false}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        auto_hide={false}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
