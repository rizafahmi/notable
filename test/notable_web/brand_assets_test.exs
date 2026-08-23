defmodule NotableWeb.BrandAssetsTest do
  @moduledoc """
  Guards the Notable brand icon set: the files exist, are the format and size
  they claim to be, are actually reachable through `Plug.Static`, and are linked
  from the document head.

  The old `favicon.ico` was a 152-byte PNG with an `.ico` extension, so these
  tests assert on real magic bytes rather than trusting the filename.
  """
  use NotableWeb.ConnCase, async: true

  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @served [
    # Plug's MIME table uses the IANA-registered type, not the legacy image/x-icon.
    {"/favicon.ico", "image/vnd.microsoft.icon"},
    {"/favicon.svg", "image/svg+xml"},
    {"/icon-mask.svg", "image/svg+xml"},
    {"/apple-touch-icon.png", "image/png"},
    {"/icon-192.png", "image/png"},
    {"/icon-512.png", "image/png"},
    {"/og-image.png", "image/png"},
    {"/site.webmanifest", nil}
  ]

  defp static_read!(path), do: File.read!(Path.join("priv/static", path))

  # PNG: 8-byte signature, 4-byte chunk length, "IHDR", then width/height as big-endian u32.
  defp png_dimensions(binary) do
    <<@png_signature, _len::32, "IHDR", width::32, height::32, _rest::binary>> = binary
    {width, height}
  end

  # ICO: reserved(0), type(1 = icon), image count, then 16-byte directory entries
  # whose first two bytes are width and height (0 meaning 256).
  defp ico_entry_sizes(<<0, 0, 1, 0, count::little-16, rest::binary>>) do
    for i <- 0..(count - 1) do
      <<_skip::binary-size(i * 16), w, h, _::binary>> = rest
      {if(w == 0, do: 256, else: w), if(h == 0, do: 256, else: h)}
    end
  end

  describe "static serving" do
    test "every brand asset is reachable through Plug.Static", %{conn: conn} do
      for {path, content_type} <- @served do
        conn = get(conn, path)

        assert conn.status == 200,
               "#{path} returned #{conn.status} - is it listed in NotableWeb.static_paths/0?"

        assert byte_size(response(conn, 200)) > 0

        if content_type do
          assert [served_type] = get_resp_header(conn, "content-type")
          assert served_type =~ content_type
        end
      end
    end

    test "static_paths/0 allowlists each new root-level brand file" do
      allowed = NotableWeb.static_paths()

      for {"/" <> filename, _} <- @served do
        assert filename in allowed,
               "#{filename} missing from NotableWeb.static_paths/0 - Plug.Static will 404 it"
      end
    end
  end

  describe "favicon.ico binary format" do
    test "is a real multi-size ICO, not a PNG wearing an .ico extension" do
      binary = static_read!("favicon.ico")

      refute binary_part(binary, 0, 8) == @png_signature,
             "favicon.ico is still a PNG - it must be a true ICO container"

      assert <<0, 0, 1, 0, _count::little-16, _::binary>> = binary
    end

    test "contains the 16, 32 and 48 pixel frames" do
      sizes = static_read!("favicon.ico") |> ico_entry_sizes()

      assert length(sizes) == 3
      assert {16, 16} in sizes
      assert {32, 32} in sizes
      assert {48, 48} in sizes
    end
  end

  describe "raster dimensions" do
    test "each PNG is exactly the size its filename and purpose promise" do
      assert png_dimensions(static_read!("apple-touch-icon.png")) == {180, 180}
      assert png_dimensions(static_read!("icon-192.png")) == {192, 192}
      assert png_dimensions(static_read!("icon-512.png")) == {512, 512}
      assert png_dimensions(static_read!("og-image.png")) == {1200, 630}
    end

    test "apple-touch-icon is opaque, since iOS renders alpha as black" do
      # PNG colour type lives in IHDR, one byte after width/height/bit-depth.
      <<@png_signature, _len::32, "IHDR", _w::32, _h::32, _depth, colour_type, _rest::binary>> =
        static_read!("apple-touch-icon.png")

      assert colour_type in [0, 2],
             "expected greyscale/truecolour without alpha, got colour type #{colour_type}"
    end
  end

  describe "vector sources" do
    test "favicon.svg carries the Nota mark on the brand surface tile" do
      svg = static_read!("favicon.svg")

      assert svg =~ ~s(viewBox="0 0 64 64")
      # accent + surface tokens from assets/css/app.css, converted to sRGB
      assert svg =~ "#00CADB"
      assert svg =~ "#071117"
    end

    test "icon-mask.svg is a single-colour silhouette for Safari pinned tabs" do
      svg = static_read!("icon-mask.svg")

      assert svg =~ "currentColor"
      refute svg =~ "#00CADB", "the mask icon must not carry brand colour"
    end
  end

  describe "site.webmanifest" do
    test "declares both maskable icon sizes and the brand theme colour", %{conn: conn} do
      manifest = conn |> get("/site.webmanifest") |> response(200) |> Jason.decode!()

      assert manifest["name"] == "Notable"
      assert manifest["theme_color"] == "#040A0F"

      sources = Enum.map(manifest["icons"], & &1["src"])
      assert "/icon-192.png" in sources
      assert "/icon-512.png" in sources
    end
  end

  describe "document head" do
    test "links the full icon set", %{conn: conn} do
      html = conn |> get("/") |> html_response(200)

      assert html =~ ~s(rel="icon")
      assert html =~ ~s(href="/favicon.svg")
      assert html =~ ~s(type="image/svg+xml")
      assert html =~ ~s(rel="apple-touch-icon")
      assert html =~ ~s(rel="mask-icon")
      assert html =~ ~s(rel="manifest")
      assert html =~ ~s(name="theme-color")
    end

    test "advertises an absolute og:image and twitter:image", %{conn: conn} do
      html = conn |> get("/") |> html_response(200)

      assert html =~ ~s(property="og:image")
      assert html =~ ~s(name="twitter:image")
      assert html =~ "http://localhost:4000/og-image.png"
    end

    test "og:image is present on secondary surfaces too", %{conn: conn} do
      html = conn |> get("/questions") |> html_response(200)
      assert html =~ ~s(property="og:image")
    end
  end

  describe "Phoenix leftovers" do
    test "the stock Phoenix bird logo is gone" do
      refute File.exists?("priv/static/images/logo.svg")
    end

    test "no Phoenix orange survives anywhere in priv/static" do
      offenders =
        Path.wildcard("priv/static/**/*.{svg,css,js,json,webmanifest}")
        |> Enum.filter(&(File.read!(&1) =~ "FD4F00"))

      assert offenders == [], "Phoenix orange (#FD4F00) still present in: #{inspect(offenders)}"
    end
  end
end
