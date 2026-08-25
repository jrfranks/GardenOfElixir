# ESP32 Plant Monitor

Authentic ESP-IDF v5.4+ firmware for a plant-monitor node. It speaks the same
MQTT v1 schema as the Fleet Console (`v1/dt|cmd|status/fleet/plant/{id}/...`)
so a flashed DevKit appears next to the Elixir simulators with no console
changes.

The physics / command engine is portable C in `core/`. Two fronts wrap it:

| Front | When to use |
|-------|-------------|
| `main/` (ESP-IDF) | Real hardware: `idf.py build flash monitor` |
| `host/` (POSIX + MQTT 3.1.1) | CI and `make esp32-host` — no Xtensa toolchain |

## MQTT contract

Devices **must** publish the aggregate `v1/dt/fleet/plant/{id}/sensors` topic
(FleetState ignores per-metric payloads). Status is retained on
`v1/status/fleet/plant/{id}` with LWT `state=offline`. Commands arrive on
`v1/cmd/fleet/plant/{id}/{action}`.

Handled actions match the console: `water_now`, `set_auto_mode`,
`set_moisture_thresholds`, `simulate_low_battery`, `ping`, `stop_water`,
`set_telemetry_interval`, plus `reboot` and `factory_reset`.

## Host-native (no ESP-IDF)

```bash
make -C esp32/plant_monitor/host test   # physics + protocol
make -C esp32/plant_monitor/host        # plant_monitor_host
MQTT_HOST=127.0.0.1 DEVICE_ID=esp32-fw-001 ./esp32/plant_monitor/host/plant_monitor_host
```

Requires a broker on `:1883` (the demo Mosquitto). The node shows up in the
Fleet Console as type `esp32`.

## Hardware (ESP-IDF)

```bash
. $HOME/esp/esp-idf/export.sh
cd esp32/plant_monitor
idf.py menuconfig          # Plant Monitor: SSID, broker URI, device id
idf.py -p /dev/ttyUSB0 build flash monitor
```

Valve open drives `CONFIG_PLANT_VALVE_GPIO` (default GPIO2, onboard LED on
many DevKits). QEMU (Espressif fork with Wi-Fi) is optional — see
`scripts/start-esp32-qemu.sh`. The supported no-hardware path is `host/`.

## Layout

```
core/           portable physics + JSON + topic schema (no ESP-IDF)
main/           app_main, Wi-Fi STA, esp_mqtt, FreeRTOS plant task
host/           POSIX MQTT 3.1.1 client + unit tests
```
