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
#     PHX_SERVER=true bin/fleet_monitor start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :fleet_monitor, FleetMonitorWeb.Endpoint, server: true
end

# Robust port configuration.
# Always respect $PORT (with safe default to 4000).
# In :dev also force loopback-only binding (from dev.exs intent) so we don't accidentally expose the demo.
port = String.to_integer(System.get_env("PORT", "4000"))

http_opts =
  if config_env() == :dev do
    [port: port, ip: {127, 0, 0, 1}]
  else
    [port: port]
  end

config :fleet_monitor, FleetMonitorWeb.Endpoint, http: http_opts

# Helpful startup log so people know exactly which port the server actually bound to
if System.get_env("MIX_ENV") != "test" do
  IO.puts("==> Fleet Console will be available at http://localhost:#{port}")
end

if config_env() == :prod do
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

  host = System.get_env("PHX_HOST") || "example.com"

  config :fleet_monitor, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :fleet_monitor, FleetMonitorWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
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
  #     config :fleet_monitor, FleetMonitorWeb.Endpoint,
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
  #     config :fleet_monitor, FleetMonitorWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# Phase 2 MQTT config — read at runtime (not compile time) for 12-factor / release compatibility
# Used by MqttBridge. Works for dev, prod releases, and docker.
mqtt_host = System.get_env("MQTT_HOST", "localhost")
mqtt_port = String.to_integer(System.get_env("MQTT_PORT", "1883"))
mqtt_user = System.get_env("MQTT_USERNAME", "")
mqtt_pass = System.get_env("MQTT_PASSWORD", "")

config :fleet_monitor, :mqtt,
  host: mqtt_host,
  port: mqtt_port,
  username: mqtt_user,
  password: mqtt_pass,
  client_id_prefix: "fleet_console"
