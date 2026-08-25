defmodule NotableWeb.ServiceWorkerController do
  @moduledoc """
  Serves `/sw.js`.

  A controller rather than a static file so the body is built from the digest
  manifest the endpoint already loaded, and so the kill switch is a runtime
  setting (`NOTABLE_SERVICE_WORKER=off`) rather than a redeploy.
  """

  use NotableWeb, :controller

  alias NotableWeb.ServiceWorker

  def show(conn, _params) do
    body =
      if ServiceWorker.enabled?(),
        do: ServiceWorker.render(endpoint_module(conn).config(:cache_static_manifest_latest)),
        else: ServiceWorker.kill_switch()

    conn
    |> put_resp_content_type("text/javascript")
    # Browsers already cap service worker scripts at 24h; make the check
    # per-navigation so a kill switch or a new build lands promptly.
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, body)
  end
end
