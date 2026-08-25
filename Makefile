# Makefile — elixir-iot-fleet-monitor
# One-command developer and demo experience. Phase 2 foundation.
# Follows the plan in docs/PHASE1_ARCHITECTURE_AND_PLAN.md

.PHONY: help setup demo demo-stop demo-firmware test lint format clean docker-up docker-down \
	esp32-host nerves-host firmware-test

help:
	@echo "elixir-iot-fleet-monitor — Phase 3 Fleet Console (The Wow)"
	@echo ""
	@echo "Targets:"
	@echo "  make demo          # Mosquitto + Phoenix dashboard + Elixir simulators"
	@echo "  make demo-firmware # Demo plus host C (ESP-IDF core) and Nerves MQTT nodes"
	@echo "  make demo-stop     # Stop background services"
	@echo "  make docker-up     # Only bring up Mosquitto"
	@echo "  make docker-down"
	@echo "  make test          # Dashboard + ESP32 host C + Nerves host tests"
	@echo "  make esp32-host    # Build the POSIX C firmware node"
	@echo "  make nerves-host   # Run Nerves firmware on MIX_TARGET=host"
	@echo "  make lint          # format + credo (if present)"
	@echo "  make format"
	@echo "  make clean"

setup:
	@echo "==> Installing Phoenix archive (if needed) and deps"
	cd dashboard && mix do deps.get, compile

docker-up:
	@echo "==> Starting Mosquitto (MQTT broker)"
	@chmod +x scripts/ensure-mosquitto.sh
	@./scripts/ensure-mosquitto.sh
	@echo "Mosquitto should be on localhost:1883"

docker-up-full:
	@echo "==> Starting full stack (Mosquitto + dashboard container) via profile"
	@if command -v docker-compose >/dev/null 2>&1; then \
		docker-compose --profile full up -d; \
	elif docker compose version >/dev/null 2>&1; then \
		docker compose --profile full up -d; \
	else \
		echo "ERROR: Neither docker-compose nor 'docker compose' found"; exit 1; \
	fi || true

docker-down:
	@if command -v docker-compose >/dev/null 2>&1; then \
		docker-compose down; \
	elif docker compose version >/dev/null 2>&1; then \
		docker compose down; \
	else \
		echo "ERROR: Neither docker-compose nor 'docker compose' found"; exit 1; \
	fi || true

docker-build:
	@echo "==> Building Phase 2 dashboard image (see Dockerfile)"
	docker build -t elixir-iot-fleet-monitor:phase2 .

demo: docker-up
	@echo "==> Phase 3 Demo: Interactive Fleet Console with cards, gauges, live commands, dynamic devices"
	@./scripts/start-demo.sh

demo-stop:
	@echo "Stopping demo processes..."
	-pkill -f "iex.*--sname.*fleet" || true
	-pkill -f "mix phx.server" || true
	-pkill -f "plant_monitor_host" || true
	-pkill -f "mix run --no-halt" || true
	@docker-compose stop mosquitto || docker compose stop mosquitto || true

esp32-host:
	$(MAKE) -C esp32/plant_monitor/host

nerves-host:
	@chmod +x scripts/start-nerves-host.sh
	@./scripts/start-nerves-host.sh

demo-firmware: docker-up esp32-host
	@echo "==> Host firmware nodes (C ESP32 core + Nerves) on MQTT, then dashboard"
	@chmod +x scripts/start-esp32-host.sh scripts/start-nerves-host.sh
	@MQTT_HOST=127.0.0.1 DEVICE_ID=esp32-fw-001 scripts/start-esp32-host.sh &
	@MQTT_HOST=127.0.0.1 DEVICE_ID=nerves-fw-001 scripts/start-nerves-host.sh &
	@./scripts/start-demo.sh

firmware-test:
	$(MAKE) -C esp32/plant_monitor/host test
	cd nerves/plant_monitor && mix deps.get && mix test

test:
	cd dashboard && mix test
	$(MAKE) -C esp32/plant_monitor/host test
	cd nerves/plant_monitor && mix deps.get && mix test

lint:
	cd dashboard && mix format --check-formatted && mix credo --strict

format:
	cd dashboard && mix format

clean:
	rm -rf dashboard/_build dashboard/deps
	rm -rf nerves/plant_monitor/_build nerves/plant_monitor/deps
	$(MAKE) -C esp32/plant_monitor/host clean
	rm -rf _build deps
	@echo "Clean complete"
