# GardenOfElixir

> A visually impressive, production-grade, hybrid IoT fleet monitoring system showcasing advanced Elixir + embedded C skills.

**Live simulated fleet of plant monitors** (soil moisture, temperature, humidity, valve control) powered by:

- **Phoenix 1.8 + LiveView** — The "Fleet Console" dashboard
- **Elixir simulators** inside the dashboard BEAM — the one-command demo (`make demo`)
- **Nerves firmware** (`nerves/plant_monitor`) — Mix project; host MQTT node or `MIX_TARGET=x86_64` image
- **ESP32 firmware** (`esp32/plant_monitor`) — ESP-IDF C (Wi-Fi, esp-mqtt, FreeRTOS) plus a POSIX host build
- **Mosquitto** as the universal communication bus

This is a **clean-slate, open-source portfolio project** designed to demonstrate senior-level capabilities across the full stack: real-time web systems, distributed BEAM architecture, realistic embedded simulation, and excellent developer experience.

---

## ✨ Why This Project Stands Out

- **True hybrid architecture** — MQTT for cross-language devices + native Distributed Erlang for Elixir/Nerves nodes (the right tool for each job)
- **One-command impressive demo** (`make demo`) — Elixir simulators; `make demo-firmware` also starts the C and Nerves MQTT nodes
- **Real, not toy, C code** — portable plant core + complete ESP-IDF app; CI compiles the host firmware (`make -C esp32/plant_monitor/host test`)
- **Production patterns** — robust reconnection, supervision, structured logging, dynamic device lifecycle, realistic physics simulation
- **Stunning LiveView UI** — gauges, live streams, optimistic controls, cluster health, event log
- **Excellent documentation** — architecture diagrams, setup for mortals, demo video, "how this maps to real production" notes

---

## 🚀 Quick Start (Phase 2+)

Once the core is built:

```bash
git clone https://github.com/jrfranks/GardenOfElixir
cd GardenOfElixir
make demo          # or ./scripts/start-demo.sh
```

The dashboard will open at http://localhost:4000 with several simulated Nerves and ESP32 devices already streaming realistic plant sensor data.

Firmware nodes (optional, same MQTT schema): `make demo-firmware` or
`scripts/start-esp32-host.sh` / `scripts/start-nerves-host.sh` after Mosquitto
is up. Hardware/QEMU steps live in `esp32/plant_monitor/README.md` and
`nerves/plant_monitor/README.md`. Topic contract: [docs/MQTT_TOPICS.md](docs/MQTT_TOPICS.md).

**Prerequisites:** Docker, Elixir 1.18+, Mix, a C compiler (`gcc`/`clang`) for the ESP32 host tests. See [Troubleshooting](#-troubleshooting) if Mosquitto or compose fails.

---

## 📁 Repository Layout

```
.
├── dashboard/          # Phoenix 1.8 LiveView Fleet Console
├── nerves/             # Nerves firmware (host MQTT node + x86_64 image)
├── esp32/              # ESP-IDF C firmware (host POSIX node + idf.py)
├── docs/               # Architecture, MQTT topics, getting started, demo script
├── diagrams/           # Mermaid architecture diagrams
├── scripts/            # start-demo.sh, ensure-mosquitto.sh, QEMU launchers
├── docker-compose.yml  # Mosquitto + optional supporting services
└── Makefile            # The magic entry point
```

See the documentation section below for the primary references.

These documents (especially `DESIGN.md`) are the primary references for understanding *why* the system is built the way it is, its theory of operation, and how to extend or maintain it.

---

## 🏗️ Current Status

| Phase | Status      | Description |
|-------|-------------|-------------|
| 1     | ✅ Complete | Architecture, naming, folder structure, versions, communication model, risks |
| 2     | ✅ Complete | Core infrastructure (Phoenix + MQTT bridge + simulators + basic LiveView) — foundation only |
| 3     | ✅ Complete | Full flashy dashboard, controls, dynamic devices, cluster health, event log ([detailed plan](docs/PHASE3_FEATURE_IMPLEMENTATION_PLAN.md)) |
| 4     | 🚧 In progress | One-command demo hardening, CI with Mosquitto, README/docs polish, production notes ([PRODUCTION.md](docs/PRODUCTION.md)) |
| Firmware | ✅ Complete | ESP-IDF C (`esp32/plant_monitor`) and Nerves (`nerves/plant_monitor`) — host builds in CI; hardware/QEMU optional |

---

## 📸 Screenshots & Demo Video

Screenshots and a short demo video are not in the repo yet. Add PNGs under `docs/screenshots/` when you capture them.

- **Screenshots path:** `docs/screenshots/` (add PNGs here when captured manually)
- **Planned video content:** live device cards, Water Now / Water All, LWT on kill, dynamic spawn, cluster health

---

## 🔧 Troubleshooting

### Mosquitto unhealthy (old healthcheck)

Older compose files used a healthcheck that failed on Mosquitto 2.x. The current `docker-compose.yml` uses `mosquitto_rr` (commit `beecd3f`). If a container is stuck unhealthy:

```bash
docker rm -f fleet-mosquitto
make docker-up
```

### `docker-compose` ContainerConfig / KeyError on recreate

`docker-compose` v1.29.2 can fail when recreating containers. The project falls back automatically:

- `make docker-up` and `make demo` call `scripts/ensure-mosquitto.sh`
- If compose fails, Mosquitto starts via `docker run` with the same image, volumes, ports, and healthcheck

### `make demo` prerequisites

| Requirement | Check |
|-------------|--------|
| Docker running | `docker ps` |
| Elixir 1.18+ | `elixir -v` |
| Port 1883 free | `ss -lntp \| grep 1883` |
| Port 4000 free | `ss -lntp \| grep 4000` |

MQTT env vars (optional): `MQTT_HOST=localhost`, `MQTT_PORT=1883` (defaults in `config/runtime.exs`).

### Tests and MQTT

CI and isolated test runs expect Mosquitto on `localhost:1883`. Start it with `make docker-up` before `cd dashboard && mix test` if the bridge logs `command publish failed`.

**CI note:** GitHub Actions uses the stock `eclipse-mosquitto:2` service image (default anonymous broker). Local `make docker-up` mounts `mosquitto/config/` — both expose `:1883` and work for tests.

---

## 🤝 Contributing & Philosophy

This project aims for **portfolio-grade quality**:
- Every file is intentional
- No "demo code" that would be embarrassing in a real system
- Comments explain *why*, not just *what*
- Tests for the physics engine and critical paths
- Zero tolerance for "it works on my machine" without scripts

---

## 📜 License

MIT — see [LICENSE](LICENSE).

---

**Built with ❤️ for the Elixir and embedded communities.**

*If you're a hiring manager or tech lead looking at this repo: this is the level of depth and craftsmanship I bring to distributed real-time systems and edge software.*