defmodule NotableWeb.ServiceWorkerControllerTest do
  @moduledoc """
  `/sw.js` is served by a controller rather than `Plug.Static` so the body can
  be built from the digest manifest the endpoint already loaded, and so the
  kill switch is a runtime setting instead of a redeploy.
  """

  # Not async: the kill-switch test flips application config.
  use NotableWeb.ConnCase, async: false

  alias NotableWeb.ServiceWorker

  setup do
    previous = Application.get_env(:notable, :service_worker)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:notable, :service_worker, previous),
        else: Application.delete_env(:notable, :service_worker)
    end)

    :ok
  end

  test "serves the worker as JavaScript from the site root", %{conn: conn} do
    conn = get(conn, "/sw.js")

    assert response(conn, 200) ==
             ServiceWorker.render(NotableWeb.Endpoint.config(:cache_static_manifest_latest))

    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "text/javascript"
  end

  test "tells the browser not to hold the worker script in its HTTP cache", %{conn: conn} do
    conn = get(conn, "/sw.js")
    assert ["no-cache"] = get_resp_header(conn, "cache-control")
  end

  test "does not start a session for a script fetch", %{conn: conn} do
    conn = get(conn, "/sw.js")
    assert conn.status == 200
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "keeps the shared security headers", %{conn: conn} do
    conn = get(conn, "/sw.js")
    assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
  end

  test "serves the kill switch when the worker is switched off", %{conn: conn} do
    Application.put_env(:notable, :service_worker, enabled: false)

    conn = get(conn, "/sw.js")

    assert response(conn, 200) == ServiceWorker.kill_switch()
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "text/javascript"
  end

  test "is enabled by default", %{conn: conn} do
    Application.delete_env(:notable, :service_worker)

    conn = get(conn, "/sw.js")

    refute response(conn, 200) == ServiceWorker.kill_switch()
  end
end
