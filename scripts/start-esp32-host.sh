#!/bin/sh
# Run the portable C plant monitor against local Mosquitto (no ESP-IDF).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/esp32/plant_monitor/host"
make -s
export MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
export MQTT_PORT="${MQTT_PORT:-1883}"
export DEVICE_ID="${DEVICE_ID:-esp32-fw-001}"
echo "Starting ESP32 host node $DEVICE_ID -> mqtt://$MQTT_HOST:$MQTT_PORT"
exec ./plant_monitor_host
