import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/notable start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :notable, NotableWeb.Endpoint, server: true
end

config :notable, NotableWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Kill switch for the app-shell service worker: `off` makes /sw.js serve a
# worker that unregisters itself and purges its caches. See
# docs/OPERATIONS.md#service-worker.
config :notable, :service_worker, enabled: System.get_env("NOTABLE_SERVICE_WORKER") != "off"

if config_env() == :prod do
  fetch_env! = fn var ->
    System.get_env(var) ||
      raise """
      environment variable #{var} is missing.
      """
  end

  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/notable/notable.db
      """

  config :notable, Notable.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    journal_mode: :wal,
    busy_timeout: 5_000,
    default_transaction_mode: :immediate

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "feedback.rizafahmi.com"

  config :notable, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  mayar_webhook_token = fetch_env!.("MAYAR_WEBHOOK_TOKEN")

  if byte_size(mayar_webhook_token) < 20 do
    raise """
    environment variable MAYAR_WEBHOOK_TOKEN is too short.
    """
  end

  config :notable, :mayar,
    base_url: fetch_env!.("MAYAR_API_BASE_URL"),
    api_key: fetch_env!.("MAYAR_API_KEY"),
    webhook_token: mayar_webhook_token

  config :notable, :admin,
    username: fetch_env!.("ADMIN_USERNAME"),
    password: fetch_env!.("ADMIN_PASSWORD")

  # Canonical: NOTABLE_*; temporary alias: DONATEX_* (keep until captain drops aliases).
  base_url =
    System.get_env("NOTABLE_BASE_URL") ||
      System.get_env("DONATEX_BASE_URL") ||
      raise """
      environment variable NOTABLE_BASE_URL is missing.
      Temporary alias DONATEX_BASE_URL is also accepted.
      """

  origin =
    case URI.parse(base_url) do
      %URI{scheme: scheme, host: host, port: nil} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}"

      %URI{scheme: scheme, host: host, port: port}
      when is_binary(scheme) and is_binary(host) and is_integer(port) ->
        "#{scheme}://#{host}:#{port}"

      _ ->
        raise """
        environment variable NOTABLE_BASE_URL is invalid.
        Temporary alias DONATEX_BASE_URL is also accepted.
        """
    end

  config :notable, :app, base_url: base_url

  config :notable, NotableWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: [origin, "https://feedback.rizafahmi.com"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :notable, NotableWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :notable, NotableWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :notable, Notable.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
