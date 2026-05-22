# Makefile — elixir-iot-fleet-monitor
# One-command developer and demo experience. Phase 2 foundation.
# Follows the plan in docs/PHASE1_ARCHITECTURE_AND_PLAN.md

.PHONY: help setup demo demo-stop test lint format clean docker-up docker-down

help:
	@echo "elixir-iot-fleet-monitor — Phase 3 Fleet Console (The Wow)"
	@echo ""
	@echo "Targets:"
	@echo "  make demo          # Start everything: mosquitto + flashy interactive dashboard + simulators"
	@echo "  make demo-stop     # Stop background services"
	@echo "  make docker-up     # Only bring up Mosquitto"
	@echo "  make docker-down"
	@echo "  make test          # Run tests in dashboard/"
	@echo "  make lint          # format + credo (if present)"
	@echo "  make format"
	@echo "  make clean"

setup:
	@echo "==> Installing Phoenix archive (if needed) and deps"
	cd dashboard && mix do deps.get, compile

docker-up:
	@echo "==> Starting Mosquitto (MQTT broker)"
	@if command -v docker-compose >/dev/null 2>&1; then \
		docker-compose up -d mosquitto; \
	elif docker compose version >/dev/null 2>&1; then \
		docker compose up -d mosquitto; \
	else \
		echo "ERROR: Neither docker-compose nor 'docker compose' found"; exit 1; \
	fi || true
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
	@docker-compose stop mosquitto || docker compose stop mosquitto || true

test:
	cd dashboard && mix test

lint:
	cd dashboard && mix format --check-formatted && mix credo --strict || true

format:
	cd dashboard && mix format

clean:
	rm -rf dashboard/_build dashboard/deps
	rm -rf _build deps
	@echo "Clean complete"
