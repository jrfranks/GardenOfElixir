#!/bin/sh
# Run Nerves firmware on MIX_TARGET=host (real MQTT node, no system image).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/nerves/plant_monitor"
mix deps.get
export MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
export MQTT_PORT="${MQTT_PORT:-1883}"
export DEVICE_ID="${DEVICE_ID:-nerves-fw-001}"
echo "Starting Nerves host node $DEVICE_ID -> mqtt://$MQTT_HOST:$MQTT_PORT"
exec mix run --no-halt
