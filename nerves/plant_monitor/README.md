# Nerves Plant Monitor

Real Nerves firmware for a plant-monitor node. Same MQTT v1 schema as the
Fleet Console and the ESP-IDF firmware (`v1/dt|cmd|status/fleet/plant/{id}`).

| Target | How |
|--------|-----|
| **host** (default) | `mix run --no-halt` — full MQTT node, no Nerves toolchain |
| **x86_64** | `MIX_TARGET=x86_64 mix firmware` — QEMU / bare metal via `nerves_system_x86_64` |

The host target is how CI and `make nerves-host` prove the firmware. Flashing
a board is documented below; it is optional for the dashboard demo.

## Host (no Nerves toolchain)

```bash
cd nerves/plant_monitor
mix deps.get
mix test
MQTT_HOST=127.0.0.1 DEVICE_ID=nerves-fw-001 mix run --no-halt
```

Requires Mosquitto on `:1883`. The node appears in the Fleet Console as type
`nerves`. Commands from the UI (`water_now`, `ping`, …) arrive over MQTT
(tortoise311), not via the dashboard PubSub path.

Optional BEAM cluster (join the Phoenix node):

```bash
CLUSTER_ENABLED=1 mix run --no-halt
```

## Firmware image (QEMU / hardware)

```bash
mix local.nerves          # once: nerves_bootstrap archive
export MIX_TARGET=x86_64
mix deps.get
mix firmware
# QEMU: see nerves_system_x86_64 docs, or scripts/start-nerves-qemu.sh
```

On device, set `MQTT_HOST` to the broker (guest `127.0.0.1` is wrong inside
QEMU). `nerves_pack` brings ssh, mDNS (`plant-monitor.local`), and DHCP on
`eth0`.

## MQTT

- Telemetry: `v1/dt/fleet/plant/{id}/sensors` (aggregate — required) plus
  per-metric topics
- Status: retained `v1/status/fleet/plant/{id}` with LWT offline
- Commands: `v1/cmd/fleet/plant/{id}/{action}`

Physics rates are copied from `dashboard/lib/fleet_monitor/plant_physics.ex`
into `lib/plant_monitor/physics.ex` — keep them in sync.
