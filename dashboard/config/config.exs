# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Allow custom metadata keys used in the demo simulators and MqttBridge
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:device, :enabled, :duration_ms, :state, :topic, :action, :error]

config :fleet_monitor,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :fleet_monitor, FleetMonitorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FleetMonitorWeb.ErrorHTML, json: FleetMonitorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FleetMonitor.PubSub,
  live_view: [signing_salt: "ljIZMqrX"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  fleet_monitor: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  fleet_monitor: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Phase 2: MQTT bridge configuration (hybrid architecture)
# Values are provided at runtime via runtime.exs (12-factor compliant).
# Defaults here are only for compile-time / test; real values come from env.
config :fleet_monitor, :mqtt,
  host: "localhost",
  port: 1883,
  username: "",
  password: "",
  client_id_prefix: "fleet_console"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
