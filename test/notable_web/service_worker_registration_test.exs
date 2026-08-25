defmodule NotableWeb.ServiceWorkerRegistrationTest do
  @moduledoc """
  The worker only helps if every audience page actually registers it. The
  registration is a separate esbuild entry loaded from the root layout - not a
  line in `app.js` - so it stays out of the way of the hooks that other work
  keeps changing, and so the layout is the one place that decides whether the
  worker exists.
  """

  use NotableWeb.ConnCase, async: true

  @register_source "assets/js/sw_register.js"

  test "the root layout loads the registration script on the audience pages", %{conn: conn} do
    for path <- ["/", "/questions"] do
      html = conn |> get(path) |> html_response(200)

      assert html =~
               ~s|<script defer phx-track-static type="text/javascript" src="/assets/js/sw_register.js">|,
             "#{path} does not load the service worker registration"
    end
  end

  test "esbuild bundles the registration script as its own entry point" do
    args = Application.fetch_env!(:esbuild, :notable)[:args]

    assert "js/sw_register.js" in args
    assert "js/app.js" in args
  end

  test "the registration script registers the worker served at the site root" do
    source = File.read!(@register_source)

    assert source =~ ~s("serviceWorker" in navigator)
    assert source =~ ~s|navigator.serviceWorker.register("/sw.js")|
  end

  test "the registration script exposes the per-browser kill switch" do
    source = File.read!(@register_source)

    assert source =~ "unregister()"
    assert source =~ "caches.delete("
  end
end
