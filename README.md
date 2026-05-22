# elixir-iot-fleet-monitor

> A visually impressive, production-grade, hybrid IoT fleet monitoring system showcasing advanced Elixir + embedded C skills.

**Live simulated fleet of plant monitors** (soil moisture, temperature, humidity, valve control) powered by:

- **Phoenix 1.8 + LiveView** — The "Fleet Console" dashboard
- **Nerves Simulator nodes** (Elixir) — using distributed Erlang + libcluster
- **ESP32 nodes** (real C / ESP-IDF) — communicating over MQTT
- **Mosquitto** as the universal communication bus

This is a **clean-slate, open-source portfolio project** designed to demonstrate senior-level capabilities across the full stack: real-time web systems, distributed BEAM architecture, realistic embedded simulation, and excellent developer experience.

---

## ✨ Why This Project Stands Out

- **True hybrid architecture** — MQTT for cross-language devices + native Distributed Erlang for Elixir/Nerves nodes (the right tool for each job)
- **One-command impressive demo** (`make demo`)
- **Real, not toy, C code** — complete ESP-IDF project that runs on actual hardware or QEMU
- **Production patterns** — robust reconnection, supervision, structured logging, dynamic device lifecycle, realistic physics simulation
- **Stunning LiveView UI** — gauges, live streams, optimistic controls, cluster health, event log
- **Excellent documentation** — architecture diagrams, setup for mortals, demo video, "how this maps to real production" notes

---

## 🚀 Quick Start (Phase 2+)

Once the core is built:

```bash
git clone https://github.com/<you>/elixir-iot-fleet-monitor
cd elixir-iot-fleet-monitor
make demo          # or ./scripts/start-demo.sh
```

The dashboard will open at http://localhost:4000 with several simulated Nerves and ESP32 devices already streaming realistic plant sensor data.

---

## 📁 Repository Layout

```
.
├── dashboard/          # Phoenix 1.8 LiveView Fleet Console
├── nerves/             # Real Nerves firmware (x86_64 QEMU + real targets)
├── esp32/              # Authentic ESP-IDF C code (plant monitor)
├── docs/               # Architecture, MQTT topics, getting started, demo script
├── diagrams/           # Mermaid architecture diagrams
├── scripts/            # start-demo.sh, QEMU launchers
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
| 4     | Planned   | One-command demo, video, README polish, Docker Compose, production notes |

---

## 📸 Screenshots & Demo (Coming Soon)

A 3–5 minute video will be recorded showing:
- Multiple device cards updating live
- Sending "Water Now" to both Nerves and ESP32 devices
- Killing a node and watching it gracefully go offline (LWT)
- Adding new devices dynamically
- Cluster health panel reacting to real BEAM nodes joining

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

---

> **Phase 1 complete.** The full architecture plan lives in `docs/PHASE1_ARCHITECTURE_AND_PLAN.md`. Ready to begin Phase 2 upon approval.