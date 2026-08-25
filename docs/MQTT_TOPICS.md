# MQTT topic schema (v1)

Authoritative wire contract for the Fleet Console, Elixir simulators, Nerves
firmware, and ESP-IDF firmware. Implemented in `dashboard` `MqttBridge` and
in both firmware trees.

```
v1/dt/fleet/plant/{device_id}/{metric}     telemetry (device → broker)
v1/cmd/fleet/plant/{device_id}/{action}    commands (console → device)
v1/status/fleet/plant/{device_id}          retained birth / LWT
```

## Telemetry

FleetState **only** applies the aggregate `sensors` topic. Per-metric topics
are for MQTT Explorer / external tools.

| Topic suffix | Payload |
|--------------|---------|
| `sensors` | `{"soil_moisture":47.3,"temperature":21.0,"humidity":68.0,"battery":91.0}` |
| `soil_moisture` | `{"value":47.3,"unit":"%","ts":<ms>}` |
| `temperature` | `{"value":21.0,"unit":"C","ts":<ms>}` |
| `humidity` | `{"value":68.0,"unit":"%","ts":<ms>}` |
| `battery` | `{"value":91.0,"unit":"%","ts":<ms>}` |

## Status (retained, QoS 1)

```json
{"state":"online","type":"nerves|esp32","fw":"0.1.0","last_seen":"<iso8601>",
 "valve_open":false,"auto_mode":true,"moisture_low":18.0,"moisture_high":52.0,
 "soil_moisture":47.3,"temperature":21.0,"humidity":68.0,"battery":91.0,
 "report_interval_closed_ms":60000,"water_to_target":false}
```

LWT payload: `{"state":"offline","reason":"disconnected","type":"..."}`.

## Commands (QoS 1)

| Action | Payload |
|--------|---------|
| `water_now` | `{"duration_ms":0}` water until Auto High; `>0` timed pulse (ms, cap 30s) |
| `stop_water` | `{}` |
| `set_auto_mode` | `{"enabled":true}` |
| `set_moisture_thresholds` | `{"low":18,"high":52}` |
| `set_telemetry_interval` | `{"interval_ms":60000}` |
| `simulate_low_battery` | `{}` |
| `ping` | `{}` (republish telemetry, no physics change) |
| `reboot` | `{}` |
| `factory_reset` | `{}` |
