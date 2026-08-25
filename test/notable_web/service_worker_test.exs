defmodule NotableWeb.ServiceWorkerTest do
  @moduledoc """
  The service worker is JavaScript and this project has no JS test runner, so
  every decision that *can* be pinned from Elixir is pinned here: what the
  worker precaches, what it must never touch, and - the expensive one - that a
  new build gets a new cache instead of serving the previous deploy forever.

  Design: docs/superpowers/specs/2026-08-25-offline-submission-design.md
  """

  use ExUnit.Case, async: true

  alias NotableWeb.ServiceWorker

  # Shaped like the `latest` map in priv/static/cache_manifest.json written by
  # `mix phx.digest`: logical path => digested path, no leading slash.
  @build_a %{
    "assets/css/app.css" => "assets/css/app-b69a392467256763b9eac5e640c8f8c5.css",
    "assets/js/app.js" => "assets/js/app-9374e305e33d917246bacc77b16268b5.js",
    "assets/js/sw_register.js" => "assets/js/sw_register-0d5e2a5c3f8a4b1c9e7d6f5a4b3c2d1e.js",
    "fonts/notable-display.woff2" =>
      "fonts/notable-display-98c1e90b3c2e11867a49a8a145d276f5.woff2",
    "favicon.svg" => "favicon-e4926393f53ab4964e1c948af212f823.svg",
    "images/qr-questions.png" => "images/qr-questions-ba10bf84d0e4cf1d1d39a146f5bd2a3b.png",
    "og-image.png" => "og-image-ebf519bb647a9cc59d3119c90f9de691.png",
    "smb_stage_clear.wav" => "smb_stage_clear-d82c39fd5aa149573ec9366082b6a2f6.wav",
    "robots.txt" => "robots-be8c39dc397b0e334570b9e6e89ad0e4.txt",
    "site.webmanifest" => "site-7f242ba8ed484f8bfea920ea9495fc68.webmanifest"
  }

  # The next deploy: app.js changed, everything else identical.
  @build_b Map.put(
             @build_a,
             "assets/js/app.js",
             "assets/js/app-ffffffffffffffffffffffffffffffff.js"
           )

  describe "precache/1 - generated from the digest manifest" do
    test "lists every digested script, stylesheet and font as an absolute path" do
      precache = ServiceWorker.precache(@build_a)

      assert "/assets/css/app-b69a392467256763b9eac5e640c8f8c5.css" in precache
      assert "/assets/js/app-9374e305e33d917246bacc77b16268b5.js" in precache
      assert "/assets/js/sw_register-0d5e2a5c3f8a4b1c9e7d6f5a4b3c2d1e.js" in precache
      assert "/fonts/notable-display-98c1e90b3c2e11867a49a8a145d276f5.woff2" in precache
    end

    test "never lists the undigested logical paths - those are not immutable" do
      for path <- ServiceWorker.precache(@build_a) do
        assert path =~ ~r/-[0-9a-f]{32}\.[a-z0-9]+$/, "#{path} is not a digested path"
      end
    end

    test "leaves out static files the audience pages do not need offline" do
      precache = ServiceWorker.precache(@build_a)

      refute Enum.any?(precache, &String.starts_with?(&1, "/images/"))
      refute Enum.any?(precache, &String.ends_with?(&1, ".wav"))
      refute Enum.any?(precache, &String.ends_with?(&1, ".txt"))
      refute Enum.any?(precache, &String.ends_with?(&1, ".webmanifest"))
      refute Enum.any?(precache, &String.contains?(&1, "og-image"))
    end

    test "is empty when there is no digest manifest (dev and test)" do
      assert ServiceWorker.precache(nil) == []
      assert ServiceWorker.precache(%{}) == []
    end
  end

  describe "config/1 - what the worker is told to cache and to leave alone" do
    test "caches exactly the two audience documents as the shell" do
      assert ServiceWorker.config(@build_a)["shell"] == ["/", "/questions"]
    end

    test "never caches admin, the LiveView socket, webhooks or dev routes" do
      never = ServiceWorker.config(@build_a)["never_cache"]

      assert "/admin" in never
      assert "/live" in never
      assert "/webhooks" in never
      assert "/dev" in never
    end

    test "nothing under /admin appears anywhere in the cacheable sets" do
      config = ServiceWorker.config(@build_a)

      for path <- config["shell"] ++ config["precache"] do
        refute String.starts_with?(path, "/admin"), "#{path} would cache an admin surface"
      end
    end

    test "network-first has a bounded wait so a lossy connection falls back to cache" do
      timeout = ServiceWorker.config(@build_a)["network_timeout_ms"]

      assert is_integer(timeout)
      assert timeout > 0
      assert timeout <= 5_000
    end
  end

  describe "stamp/1 - a new build must get a new cache" do
    test "changes when a build produces different digested assets" do
      refute ServiceWorker.stamp(@build_a) == ServiceWorker.stamp(@build_b)
    end

    test "is deterministic for byte-identical builds, so an unchanged deploy does not churn" do
      assert ServiceWorker.stamp(@build_a) == ServiceWorker.stamp(@build_a)
    end

    test "is a short hex token safe to use in a cache name" do
      assert ServiceWorker.stamp(@build_a) =~ ~r/^[0-9a-f]{16}$/
    end
  end

  describe "render/1 - the worker source served at /sw.js" do
    test "embeds the config and names the cache after the stamp" do
      source = ServiceWorker.render(@build_a)
      config = ServiceWorker.config(@build_a)

      assert source =~ Jason.encode!(config)
      assert source =~ ~s(notable-)
      assert source =~ config["stamp"]
      refute source =~ "__NOTABLE_SW_CONFIG__"
    end

    test "the second build's worker serves the second build's assets, not the first's" do
      first = ServiceWorker.render(@build_a)
      second = ServiceWorker.render(@build_b)

      assert first =~ "app-9374e305e33d917246bacc77b16268b5.js"
      assert second =~ "app-ffffffffffffffffffffffffffffffff.js"
      refute second =~ "app-9374e305e33d917246bacc77b16268b5.js"
      refute first == second
    end

    test "takes over promptly and drops caches from earlier builds on activate" do
      source = ServiceWorker.render(@build_a)

      assert source =~ "skipWaiting()"
      assert source =~ "clients.claim()"
      assert source =~ "caches.delete("
    end
  end

  describe "kill_switch/0 - the way out of a bad deploy" do
    test "unregisters itself and purges every cache, and caches nothing new" do
      source = ServiceWorker.kill_switch()

      assert source =~ "registration.unregister()"
      assert source =~ "caches.delete("
      assert source =~ "skipWaiting()"
      refute source =~ "cache.put("
      refute source =~ "addEventListener(\"fetch\""
    end
  end
end
