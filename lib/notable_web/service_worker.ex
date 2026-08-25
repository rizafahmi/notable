defmodule NotableWeb.ServiceWorker do
  @moduledoc """
  Builds the service worker served at `/sw.js` from the digest manifest.

  The worker caches the app shell so `/` and `/questions` load on a connection
  that cannot load anything else - piece 2 of the offline-submission design in
  `docs/superpowers/specs/2026-08-25-offline-submission-design.md`.

  The JavaScript lives in `service_worker/sw.js` (and `kill.js` for the kill
  switch) and is read at compile time. What it caches is decided here, in
  Elixir, where it can be tested:

    * `precache/1` - the digested scripts, stylesheets and web fonts from
      `mix phx.digest`'s manifest, so the list never rots by hand.
    * `config/1` - the shell documents, the paths that must never be cached,
      and the network-first timeout.
    * `stamp/1` - a build identifier that changes whenever the worker source
      or the digested assets change, so a new deploy gets a new cache and the
      previous one is deleted on activate.
  """

  @sw_source Path.join(__DIR__, "service_worker/sw.js")
  @kill_source Path.join(__DIR__, "service_worker/kill.js")
  @external_resource @sw_source
  @external_resource @kill_source
  @template File.read!(@sw_source)
  @kill_switch File.read!(@kill_source)

  @placeholder "__NOTABLE_SW_CONFIG__"

  # The two audience documents. Not the display pages, not admin.
  @shell ["/", "/questions"]

  # Prefix-matched on the request path; the worker steps aside for all of these.
  @never_cache ["/admin", "/live", "/webhooks", "/dev", "/phoenix"]

  # Extensions in the digest manifest that the shell needs offline: the bundled
  # script and stylesheet plus the web font. Not the OFL notice beside the font,
  # not images, not robots/sitemap/manifest.
  @precache_extensions [".js", ".css", ".woff2"]

  # How long network-first waits for a document before serving the cached copy.
  @network_timeout_ms 3_000

  @type latest :: %{optional(String.t()) => String.t()} | nil

  @doc "Whether `/sw.js` serves the real worker (`true`) or the kill switch."
  @spec enabled?() :: boolean()
  def enabled? do
    :notable
    |> Application.get_env(:service_worker, [])
    |> Keyword.get(:enabled, true)
  end

  @doc "The worker source with the config for this build substituted in."
  @spec render(latest()) :: String.t()
  def render(latest) do
    String.replace(@template, @placeholder, Jason.encode!(config(latest)))
  end

  @doc "The self-removing worker source; see `docs/OPERATIONS.md#service-worker`."
  @spec kill_switch() :: String.t()
  def kill_switch, do: @kill_switch

  @doc "Everything the worker is told, including the build stamp."
  @spec config(latest()) :: map()
  def config(latest) do
    base = base_config(latest)
    Map.put(base, "stamp", stamp_for(base))
  end

  @doc """
  Build identifier used in the cache name.

  Derived from the worker source and the precache list, so it changes when
  either does and stays identical for a byte-identical rebuild.
  """
  @spec stamp(latest()) :: String.t()
  def stamp(latest), do: latest |> base_config() |> stamp_for()

  @doc "Absolute paths of the digested assets the shell needs, from the manifest."
  @spec precache(latest()) :: [String.t()]
  def precache(latest) when is_map(latest) do
    latest
    |> Enum.filter(fn {logical, _digested} -> Path.extname(logical) in @precache_extensions end)
    |> Enum.map(fn {_logical, digested} -> "/" <> digested end)
    |> Enum.sort()
  end

  def precache(nil), do: []

  defp base_config(latest) do
    %{
      "shell" => @shell,
      "precache" => precache(latest),
      "never_cache" => @never_cache,
      "network_timeout_ms" => @network_timeout_ms
    }
  end

  defp stamp_for(base) do
    :sha256
    |> :crypto.hash([@template, Jason.encode!(base)])
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
