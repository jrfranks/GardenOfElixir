import Config

config :plant_monitor,
  device_id: System.get_env("DEVICE_ID") || "nerves-fw-001",
  mqtt_host: System.get_env("MQTT_HOST") || "127.0.0.1",
  mqtt_port: String.to_integer(System.get_env("MQTT_PORT") || "1883"),
  cluster_enabled: System.get_env("CLUSTER_ENABLED") in ["1", "true"]
