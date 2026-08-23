defmodule NotableWeb.Plugs.SEO do
  @moduledoc """
  Plug to assign SEO-related metadata (description, robots, canonical URL,
  Open Graph image) to the connection so they are available when rendering the
  root layout.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    base_url =
      (Application.get_env(:notable, :app)[:base_url] || "https://feedback.rizafahmi.com")
      |> String.trim_trailing("/")

    path = conn.request_path

    # Site-wide brand card. Assigned before the per-path branch so every surface
    # carries it, including the ones that fall through to the catch-all clause.
    conn = assign(conn, :og_image, base_url <> "/og-image.png")

    case path do
      "/" ->
        conn
        |> assign(
          :meta_description,
          "Kirim masukan, saran, atau pesan secara gratis. Anda juga dapat memberikan tip apresiasi via QRIS untuk mendukung kreator."
        )
        |> assign(:meta_robots, "index, follow, max-snippet:150, max-image-preview:large")
        |> assign(:canonical_url, base_url <> "/")

      "/overlay" ->
        conn
        |> assign(
          :meta_description,
          "OBS stream overlay page for displaying live alerts and emoji reactions."
        )
        |> assign(:meta_robots, "noindex, nofollow")
        |> assign(:canonical_url, base_url <> "/overlay")

      "/admin" ->
        conn
        |> assign(:meta_description, "Administrative console for managing notes and tips.")
        |> assign(:meta_robots, "noindex, nofollow")
        |> assign(:canonical_url, base_url <> "/admin")

      "/questions" ->
        conn
        |> assign(
          :meta_description,
          "Ajukan pertanyaan untuk Riza dan beri upvote anonim. Pertanyaan langsung tampil di papan hari ini."
        )
        |> assign(:meta_robots, "noindex, follow")
        |> assign(:canonical_url, base_url <> "/questions")

      "/admin/questions" ->
        conn
        |> assign(
          :meta_description,
          "Moderasi pertanyaan audiens: tandai terjawab, sembunyikan, dan kembalikan."
        )
        |> assign(:meta_robots, "noindex, nofollow")
        |> assign(:canonical_url, base_url <> "/admin/questions")

      _ ->
        conn
    end
  end
end
