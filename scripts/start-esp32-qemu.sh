#!/bin/sh
# ESP32 QEMU is optional. The supported no-hardware path is the host C node.
# If IDF_PATH + espressif qemu are installed, this prints the flash/qemu
# commands; otherwise it execs the POSIX MQTT firmware (same C core).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -n "$IDF_PATH" ] && command -v idf.py >/dev/null 2>&1 && command -v qemu-system-xtensa >/dev/null 2>&1; then
  echo "ESP-IDF + QEMU detected. Build and run:"
  echo "  cd $ROOT/esp32/plant_monitor"
  echo "  idf.py build"
  echo "  idf.py qemu"
  echo "Host-native C node (same protocol) is still the CI path:"
  echo "  $ROOT/scripts/start-esp32-host.sh"
  exit 0
fi

echo "QEMU/ESP-IDF not found — starting host-native C firmware (identical MQTT schema)."
exec "$ROOT/scripts/start-esp32-host.sh"
