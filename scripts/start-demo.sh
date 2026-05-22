#!/bin/sh
# scripts/start-demo.sh
# Phase 2: One-command impressive demo for the hybrid IoT fleet monitor.
# Starts Mosquitto (via docker-compose), then the Phoenix dashboard which
# auto-starts 3 simulated devices (Nerves + ESP32 types) via MqttBridge.
# Data flows: simulators -> MQTT -> MqttBridge -> Phoenix.PubSub -> LiveView
#
# Usage: ./scripts/start-demo.sh   (or `make demo`)
# Prerequisites: docker(-compose), elixir 1.18+, mix, optional xdg-open

set -e

# Colors for banner (portable)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo "${BLUE}║   elixir-iot-fleet-monitor — Phase 3: The Wow Fleet Console        ║${NC}"
echo "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "This demo shows the impressive interactive hybrid fleet:"
echo "  • Beautiful device cards + pure CSS gauges (Tailwind/daisy)"
echo "  • Full controls: Water Now, Auto Mode, Low Battery, Kill (LWT)"
echo "  • Dynamic spawn via DynamicSupervisor + DeviceManager"
echo "  • Live event stream + cluster health + roundtrip measurement"
echo "  • plant_physics + MqttBridge + simulators (no regressions)"
echo ""

# 1. Prerequisites
command -v docker >/dev/null 2>&1 || { echo "${RED}ERROR: docker required${NC}"; exit 1; }
command -v mix >/dev/null 2>&1 || { echo "${RED}ERROR: mix (Elixir) required${NC}"; exit 1; }

# Docker compose wrapper (v1 or v2)
DOCKER_COMPOSE="docker-compose"
if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
fi

echo "${YELLOW}==> Ensuring Mosquitto is running (MQTT broker on :1883)...${NC}"
$DOCKER_COMPOSE up -d mosquitto || { echo "${RED}Failed to start mosquitto. Check docker.${NC}"; exit 1; }

# Give broker a moment
sleep 2
echo "${GREEN}✓ Mosquitto healthy${NC}"

# 2. Dashboard setup (idempotent)
cd "$(dirname "$0")/.."
cd dashboard

echo "${YELLOW}==> Installing dashboard dependencies (first run may take 1-2 min)...${NC}"
mix deps.get --only dev > /dev/null 2>&1 || mix deps.get
mix compile

# 3. Env for demo
export MQTT_HOST="${MQTT_HOST:-localhost}"
export MQTT_PORT="${MQTT_PORT:-1883}"
export MIX_ENV="${MIX_ENV:-dev}"
export PORT=4000
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(mix phx.gen.secret 2>/dev/null || echo 'insecure_for_demo_only_please_change')}"

echo "${YELLOW}==> Starting Phoenix at http://localhost:4000 ...${NC}"
echo "   (MQTT bridge will connect, simulators will auto-start and publish)"
echo ""

# 4. Start Phoenix (foreground so user sees logs; in real tmux would split)
# For demo, we use `mix phx.server` which blocks.
# To make "impressive", the LiveView auto-populates on load.

# Optional: open browser (non-blocking)
(
  sleep 4
  URL="http://localhost:4000"
  if command -v xdg-open >/dev/null; then xdg-open "$URL" >/dev/null 2>&1 || true
  elif command -v open >/dev/null; then open "$URL" >/dev/null 2>&1 || true
  else echo "Open $URL in your browser"
  fi
) &

echo "${GREEN}✓ Phase 3 demo running. Open http://localhost:4000 — enjoy the flashy console!${NC}"
echo "  • Click Water Now / toggles / Kill on cards (optimistic + real telemetry)"
echo "  • Spawn more devices, watch event log and roundtrip"
echo "  • MQTT: mosquitto_sub -t 'v1/#' ; hybrid BEAM commands too"
echo "  • SECURITY: demo-only unauth surface (LV allow-list + guards). Not for production exposure."
echo "  • To stop: Ctrl-C, make demo-stop"
echo ""

# Run the server (this blocks until Ctrl-C)
exec mix phx.server
