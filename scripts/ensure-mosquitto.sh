#!/bin/sh
# scripts/ensure-mosquitto.sh
# Start Mosquitto for demo/tests with docker-compose fallback to docker run.
# Handles docker-compose v1.29.2 ContainerConfig KeyError by falling back to
# `docker run` with the same image, volumes, ports, and healthcheck as compose.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

wait_for_mosquitto_healthy() {
  timeout=60
  elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' fleet-mosquitto 2>/dev/null || echo "missing")

    if [ "$status" = "healthy" ]; then
      echo "==> Mosquitto healthy"
      return 0
    fi

    if [ "$status" = "unhealthy" ]; then
      echo "ERROR: fleet-mosquitto is unhealthy — try: docker rm -f fleet-mosquitto && make docker-up" >&2
      return 1
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  echo "ERROR: fleet-mosquitto did not become healthy within ${timeout}s (last: ${status})" >&2
  return 1
}

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'fleet-mosquitto'; then
  echo "==> fleet-mosquitto already running — checking health"
  wait_for_mosquitto_healthy
  exit 0
fi

# Stopped container with the same name blocks `docker run`
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'fleet-mosquitto'; then
  echo "==> Removing stopped fleet-mosquitto container"
  docker rm -f fleet-mosquitto >/dev/null 2>&1 || true
fi

compose_up() {
  if docker compose version >/dev/null 2>&1; then
    docker compose up -d mosquitto
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d mosquitto
  else
    return 1
  fi
}

echo "==> Starting Mosquitto via docker compose..."
if compose_up 2>/dev/null; then
  echo "==> Mosquitto started via compose"
  wait_for_mosquitto_healthy
  exit 0
fi

echo "==> Compose failed — falling back to docker run (ContainerConfig workaround)"
docker run -d \
  --name fleet-mosquitto \
  -p 1883:1883 \
  -v "$ROOT/mosquitto/config:/mosquitto/config:ro" \
  -v fleet-mosquitto_data:/mosquitto/data \
  -v fleet-mosquitto_log:/mosquitto/log \
  --health-cmd 'mosquitto_rr -t healthcheck -e healthcheck -m probe -W 3 --quiet --host localhost' \
  --health-interval 10s \
  --health-timeout 5s \
  --health-retries 3 \
  --health-start-period 10s \
  --restart unless-stopped \
  eclipse-mosquitto:2 \
  mosquitto -c /mosquitto/config/mosquitto.conf

echo "==> Mosquitto started via docker run on localhost:1883"
wait_for_mosquitto_healthy