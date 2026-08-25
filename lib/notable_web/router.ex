defmodule NotableWeb.Router do
  use NotableWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug NotableWeb.Plugs.VisitorId
    plug :fetch_live_flash
    plug :put_root_layout, html: {NotableWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, NotableWeb.SecurityHeaders.headers()
    plug NotableWeb.Plugs.SEO
  end

  pipeline :admin do
    plug NotableWeb.Plugs.AdminBasicAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :put_secure_browser_headers, NotableWeb.SecurityHeaders.headers()
  end

  pipeline :service_worker do
    plug :accepts, ["js"]
    plug :put_secure_browser_headers, NotableWeb.SecurityHeaders.headers()
  end

  pipeline :mayar_webhook do
    plug NotableWeb.Plugs.MayarWebhookAuth
  end

  scope "/", NotableWeb do
    pipe_through :browser

    # get "/", PageController, :home

    live "/", DonateLive
    get "/donate", PageController, :redirect_to_root
    live "/overlay", OverlayLive
    live "/qr", QrCodeLive
    live "/questions", QuestionLive
    live "/qr-overlay", QrOverlayLive
    live "/cloud", FeedbackCloudLive, :page
    live "/cloud-overlay", FeedbackCloudLive, :overlay
  end

  scope "/", NotableWeb do
    pipe_through [:browser, :admin]

    live_session :admin, on_mount: [NotableWeb.LiveAdminAuth] do
      live "/admin", AdminLive
      live "/admin/questions", AdminQuestionLive
    end
  end

  # Served from the root so the worker's scope covers the whole site. Not in
  # the :browser pipeline: a script fetch must not mint a session or a CSRF token.
  scope "/", NotableWeb do
    pipe_through :service_worker

    get "/sw.js", ServiceWorkerController, :show
  end

  scope "/", NotableWeb do
    pipe_through [:api, :mayar_webhook]

    post "/webhooks/mayar/:token", MayarWebhookController, :create
  end

  # Other scopes may use custom stacks.
  # scope "/api", NotableWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:notable, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: NotableWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
