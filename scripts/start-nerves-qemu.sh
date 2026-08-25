#!/bin/sh
# Nerves QEMU needs MIX_TARGET=x86_64 + nerves_system_x86_64 artifacts.
# Default: host Mix target (same Elixir firmware, talks MQTT).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${MIX_TARGET:-host}" != "host" ]; then
  echo "Build firmware with:"
  echo "  cd $ROOT/nerves/plant_monitor && MIX_TARGET=x86_64 mix deps.get && MIX_TARGET=x86_64 mix firmware"
  echo "Then follow nerves_system_x86_64 QEMU notes (fwup + qemu-system-x86_64)."
  exit 0
fi

echo "MIX_TARGET=host — starting Nerves firmware as a local MQTT node."
exec "$ROOT/scripts/start-nerves-host.sh"
