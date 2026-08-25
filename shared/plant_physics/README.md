Shared physics is duplicated on purpose so firmware does not depend on Phoenix:

- Elixir dashboard: `dashboard/lib/fleet_monitor/plant_physics.ex`
- Nerves firmware: `nerves/plant_monitor/lib/plant_monitor/physics.ex` (keep rates in sync)
- ESP32 C: `esp32/plant_monitor/core/plant_physics.c` (same moisture/valve rates; FNV noise for ESP32 personality)

See `docs/MQTT_TOPICS.md` for the wire schema those engines publish.
