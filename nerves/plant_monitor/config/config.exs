import Config

config :plant_monitor,
  target: Mix.target(),
  start_mqtt: true,
  start_plant: true

config :logger, :console, format: "$time $metadata[$level] $message\n"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end

import_config "#{config_env()}.exs"
