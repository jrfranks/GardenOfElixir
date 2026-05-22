# Phase 1: Architecture & Planning — elixir-iot-fleet-monitor

**Status:** Complete (ready for user approval)  
**Phase 2 Implementation:** ✅ Foundation complete (see /tmp/grok-impl-summary-b1836d53.md for details) 
**Date:** 2026  
**Author:** Grok (Elixir + Embedded Systems Architect) + User collaboration

---

## 1. Final Project Name Recommendation

**Primary Recommendation:** `elixir-iot-fleet-monitor`

**Rationale:**
- Descriptive, searchable on GitHub ("elixir iot", "fleet monitor", "nerves esp32").
- Professional for recruiters and hiring managers scanning embedded + distributed systems experience.
- Matches the exact goal stated in the query.

**Strong Alternatives (pick one if you prefer):**

| Name                        | Tagline                              | Why It Wins                                      | GitHub SEO Strength |
|-----------------------------|--------------------------------------|--------------------------------------------------|---------------------|
| `elixir-fleet-lab`          | "Hybrid IoT Fleet Simulation Lab"   | Modern, "lab" implies experimental + demo        | Excellent           |
| `hybrid_fleet_ex`           | "Nerves + ESP32 Fleet at Scale"     | Explicitly calls out the hybrid magic            | Very good           |
| `nerves_esp32_fleet`        | "Real BEAM + Real C in One Console" | Technical honesty, great for Nerves community    | Strong in niche     |
| `verdant_fleet`             | "The Garden of Elixir — IoT Plants" | Ties beautifully to plant-monitor theme + your workspace name | Fun + memorable     |
| `fleet_console_ex`          | "Production-Grade IoT Command Center" | Emphasizes the flashy LiveView dashboard         | Good                |

**Decision:** We will use `elixir-iot-fleet-monitor` as the canonical name and GitHub repo name unless you instruct otherwise. The internal Elixir OTP app name will be `FleetMonitor`.

**Repo URL convention:** `https://github.com/<your-org>/elixir-iot-fleet-monitor`

---

## 2. High-Level Architecture (Hybrid Simulation)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           FLEET CONSOLE (Phoenix 1.8 + LiveView)            │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  LiveView Dashboard (Tailwind 4 + daisyUI)                            │  │
│  │  • Device Grid (cards with gauges, progress, controls)                │  │
│  │  • Cluster Health (Erlang nodes, MQTT clients, msg rate, latency)     │  │
│  │  • Live Event Stream (phx-update="stream")                            │  │
│  │  • Dynamic "Spawn Device" + per-device actions                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌──────────────────────────────┐     ┌───────────────────────────────┐   │
│  │  MqttBridge GenServer        │◄───►│  Phoenix.PubSub (distributed) │   │
│  │  • emqtt (or mqttx) client   │     │  • "fleet:telemetry"          │   │
│  │  • Subscribes dt/fleet/#     │     │  • "fleet:events"             │   │
│  │  • Publishes cmd/fleet/...   │     │  • Cluster broadcasts         │   │
│  │  • Normalizes & fans out     │     └───────────────────────────────┘   │
│  └──────────────────────────────┘                                           │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  FleetSupervisor + DynamicSupervisor (device simulators)             │  │
│  │  • NervesPlantSimulator (Elixir GenServer, realistic physics)        │  │
│  │  • Esp32PlantSimulator (Elixir GenServer, mirrors C behavior)        │  │
│  │  • Each publishes to central MQTT client or direct PubSub            │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  libcluster (Gossip or EPMD) + Node monitoring                       │  │
│  │  • Detects real Nerves QEMU nodes joining the BEAM cluster           │  │
│  │  • Exposes Node.list() / connected count in dashboard               │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                      ▲
                                      │ MQTT (Mosquitto) 1883 / 8883 (TLS later)
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
┌───────▼────────┐          ┌─────────▼──────────┐       ┌──────────▼──────────┐
│ NERVES SIM     │          │  NERVES REAL       │       │ ESP32 SIM / REAL    │
│ (Elixir)       │          │  (QEMU or HW)      │       │ (QEMU / Wokwi / HW) │
│                │          │                    │       │                     │
│ • libcluster   │          │ • nerves_system_   │       │ • ESP-IDF v5.4+     │
│ • emqtt /      │          │   x86_64           │       │ • esp-mqtt component│
│   tortoise     │          │ • nerves_pack      │       │ • FreeRTOS tasks    │
│ • Same logic   │          │ • libcluster       │       │ • Simulated sensors │
│   as real      │          │ • Distributed      │       │ • JSON over MQTT    │
│                │          │   Erlang commands  │       │                     │
│ Multiple       │          │                    │       │ 1–N instances       │
│ instances via  │          │ Optional: joins    │       │                     │
│ DynamicSup or  │          │ Phoenix cluster    │       │                     │
│ separate nodes │          │ directly           │       │                     │
└────────────────┘          └────────────────────┘       └─────────────────────┘
```

**Key Design Principle (Production Minded):**
- **MQTT** = universal, language-agnostic, firewall-friendly bus for **all** devices (the "common tongue").
- **Distributed Erlang + libcluster** = high-performance, secure, zero-copy control & telemetry plane **only for Elixir nodes**. This is the advanced skill demonstration.
- The Phoenix `MqttBridge` + `FleetState` are the only places that understand both worlds.

---

## 3. Communication Architecture (Detailed)

### 3.1 MQTT Topic Design (v1, production-grade)

```
v1/dt/fleet/plant/{device_id}/{metric}          # Telemetry (device → broker)
v1/cmd/fleet/plant/{device_id}/{action}         # Commands (console → device)
v1/evt/fleet/plant/{device_id}/{event}          # Events / ACKs / Birth certificates
v1/status/fleet/plant/{device_id}               # Retained last-will + birth (online/offline)
```

**Examples:**
- `v1/dt/fleet/plant/nerves-001/soil_moisture` → `{"value": 47.3, "unit":"%", "ts": 1748...}`
- `v1/cmd/fleet/plant/esp32-042/water_now` → `{"duration_ms": 8000, "correlation_id": "abc123"}`
- `v1/status/fleet/plant/nerves-001` (retained) → `{"state":"online","type":"nerves","fw":"0.1.0","last_seen":...}`

**LWT (Last Will Testament):** Every device sets a will on `v1/status/...` with `state: "offline"`.

**Why this structure?**
- Clear separation of telemetry vs commands (easy ACLs later).
- Wildcard subscription `v1/dt/fleet/plant/+/#` for the bridge.
- Per-device ACL friendly (`devices/{id}/#` pattern).
- Version prefix for future evolution.
- Matches 2026 best practices from AWS IoT, HiveMQ, EMQX.

### 3.2 Distributed Erlang Layer (Elixir-only superpowers)

- Phoenix node + any Nerves simulator nodes (or real QEMU Nerves nodes) form a cluster using **libcluster** (Gossip strategy recommended for LAN/demo, EPMD or static peers for containers).
- `DeviceRegistry` (via `:pg` or custom via `Registry` + `Node.monitor`) tracks which nodes are "alive" as first-class BEAM processes.
- Commands to Nerves devices can be sent **two ways** (showing both):
  1. Via MQTT (universal path).
  2. Via direct `GenServer.call({device_pid, node}, {:water_now, opts})` — ultra low latency, no serialization, demonstrates why you keep Elixir nodes in the cluster.
- Telemetry from clustered Nerves nodes can be broadcast via `Phoenix.PubSub` (distributed) in addition to MQTT.

This is the "wow" moment for interviewers: "See how we get sub-millisecond command propagation to native Elixir devices while still supporting C devices over the standard IoT protocol."

### 3.3 Integration Points

| From / To              | Path                          | Latency | When Used                          |
|------------------------|-------------------------------|---------|------------------------------------|
| ESP32 → Phoenix        | MQTT → MqttBridge → PubSub    | ~5-50ms | All ESP32 devices                  |
| Nerves (clustered) →   | Distributed PubSub or direct  | <1ms    | Preferred for Elixir fleet members |
| Phoenix → Nerves       | Direct call or PubSub         | <1ms    | "Kill Node", advanced controls     |
| Phoenix → any device   | MQTT cmd topic                | 5-50ms  | Universal fallback                 |
| External tools         | MQTT (MQTT Explorer, etc.)    | -       | Debugging / demos                  |

---

## 4. Recommended Technology Stack & Versions (2026)

**Core Runtime**
- Elixir 1.18+ (latest stable)
- Erlang/OTP 27+
- Phoenix 1.8.7 (with LiveView ~0.21, Tailwind 4 + daisyUI 5)
- Node.js 20+ (only for asset build, optional in CI)

**Elixir Dependencies (dashboard + simulators)**
- `phoenix ~> 1.8`
- `phoenix_live_view ~> 1.0`
- `libcluster ~> 3.4` (Gossip + EPMD strategies)
- `emqtt ~> 1.13` (or `mqttx ~> 0.11` if pure-Elixir preference wins — emqtt is more proven for production IoT)
- `jason ~> 1.4`
- `telemetry ~> 1.3`
- `ring_logger` or `logger_json` for structured logs

**Nerves Side**
- `nerves ~> 1.14`
- `nerves_pack ~> 0.7`
- `nerves_system_x86_64 ~> 1.33` (or `nerves_system_qemu_aarch64`)
- `libcluster ~> 3.4`
- `emqtt` or `tortoise311` (tortoise is historically very popular on Nerves)

**Infrastructure**
- Eclipse Mosquitto 2.x (Docker `eclipse-mosquitto:2`)
- Docker Compose v2+
- (Optional but recommended) PostgreSQL 16 + TimescaleDB extension for historical telemetry in Phase 4 polish

**ESP32**
- ESP-IDF v5.4 or v5.5 (stable 2026 releases)
- `esp-mqtt` component (bundled)
- QEMU: `espressif/qemu` + community WiFi emulation fork (`emb-team/esp-idf-qemu`) for realistic TCP/MQTT over simulated WiFi

**Why emqtt over Tortoise for the central bridge?**
- Higher performance, MQTT 5.0 first-class, maintained by EMQX team, excellent reconnection + backoff.
- Tortoise remains excellent choice for the actual Nerves device firmware (many battle-tested examples).

---

## 5. Detailed Repository Structure (Monorepo — Portfolio Optimized)

```
elixir-iot-fleet-monitor/
├── README.md                          # Hero + badges + 60s video + quick start
├── LICENSE
├── Makefile                           # demo, demo-full, build-all, test, lint, docs
├── docker-compose.yml                 # mosquitto + (optional) prometheus/grafana
├── .env.example
├── .tool-versions                     # asdf or rtx
├── .github/
│   ├── workflows/
│   │   ├── ci.yml                     # test + dialyzer + credo + build firmware
│   │   └── demo.yml                   # nightly demo image?
│   └── FUNDING.yml
│
├── docs/
│   ├── PHASE1_ARCHITECTURE_AND_PLAN.md   # This file (living document)
│   ├── GETTING_STARTED.md
│   ├── ARCHITECTURE.md                # Mermaid diagrams + deep explanations
│   ├── MQTT_TOPICS.md
│   └── DEMO_SCRIPT.md                 # For recording the 3–5 min video
│
├── diagrams/
│   ├── architecture.mmd               # Mermaid source
│   └── dataflow.mmd
│
├── scripts/
│   ├── start-demo.sh                  # The magic one-command (POSIX + bash/ksh)
│   ├── start-nerves-qemu.sh
│   └── start-esp32-qemu.sh
│
├── dashboard/                         # Phoenix 1.8 umbrella or single app (single is simpler)
│   ├── mix.exs
│   ├── config/
│   │   ├── config.exs
│   │   ├── dev.exs
│   │   ├── prod.exs
│   │   └── runtime.exs                # All secrets via env
│   ├── lib/
│   │   ├── fleet_monitor/
│   │   │   ├── application.ex
│   │   │   ├── mqtt_bridge.ex         # Core production-grade MQTT client
│   │   │   ├── fleet_state.ex         # ETS-backed or GenServer registry of devices
│   │   │   ├── device_registry.ex     # :pg + Node monitoring
│   │   │   ├── simulators/
│   │   │   │   ├── device_simulator.ex   # Behaviour
│   │   │   │   ├── nerves_plant.ex
│   │   │   │   └── esp32_plant.ex
│   │   │   ├── plant_physics.ex       # Pure functions for realistic simulation (moisture decay, etc.)
│   │   │   └── commands.ex
│   │   └── fleet_monitor_web/
│   │       ├── components/            # LiveView function components + gauges
│   │       ├── live/
│   │       │   ├── fleet_console_live.ex
│   │       │   └── device_card_live.ex (optional LiveComponent)
│   │       └── hooks/                 # JS for nice progress/gauge animations
│   ├── assets/
│   │   ├── css/
│   │   │   └── app.css                # Tailwind 4 + custom IoT theme
│   │   ├── js/
│   │   │   └── app.js
│   │   └── vendor/
│   ├── priv/
│   └── test/
│
├── nerves/                            # Real Nerves firmware (x86_64 QEMU + real HW later)
│   └── plant_monitor/
│       ├── mix.exs
│       ├── config/
│       │   └── target.exs
│       ├── lib/
│       │   └── plant_monitor/
│       │       ├── application.ex
│       │       ├── mqtt_client.ex     # Uses same logic or shared dep
│       │       ├── sensors.ex
│       │       └── valve.ex
│       └── rootfs_overlay/
│
├── esp32/                             # Authentic C/ESP-IDF code
│   └── plant_monitor/
│       ├── CMakeLists.txt
│       ├── main/
│       │   ├── CMakeLists.txt
│       │   ├── app_main.c
│       │   ├── mqtt_client.c          # esp_mqtt_client
│       │   ├── sensors.c              # Simulated I2C/ADC drivers
│       │   ├── valve.c
│       │   └── config.h
│       └── components/                # Any custom components
│
├── shared/                            # (Future) Extracted logic for true DRY between Nerves & sim
│   └── plant_physics/                 # Pure Elixir (or C if ambitious) for sensor models
│
├── test/                              # Integration tests (MQTT round-trips, etc.)
│
├── .formatter.exs
├── .credo.exs
├── .dialyzer_ignore.exs
└── mix.exs (at root for umbrella if we go that route — currently leaning single Phoenix + sub-apps)
```

**Why monorepo?**
- One clone = entire story.
- Recruiters see embedded C, Elixir distributed systems, Phoenix real-time UI, Docker infra, simulation physics, and documentation in a single professional repo.
- Easy to keep the simulator logic in sync with the real firmware during development.

---

## 6. Nerves & ESP32 Integration Strategy

### 6.1 Nerves Simulator Nodes (Elixir)

**Demo Path (always works, flashy):**
- `FleetMonitor.Simulators.NervesPlant` GenServer started dynamically.
- Uses `Process.send_after` for realistic telemetry cadence (2–5s).
- `plant_physics.ex` contains pure functions:
  - `update_moisture(current, valve_open?, temp, dt)` — exponential decay + irrigation boost
  - `daily_temperature_cycle(hour)` — sine wave with noise
  - Battery drain model, auto-mode logic (hysteresis on moisture thresholds)

**Real Nerves Path (advanced / optional in demo):**
- Separate `nerves/plant_monitor` project.
- Shares (or copies with comment) the physics module.
- Configured with `libcluster` Gossip + `nerves_pack` + mDNS.
- When you run the QEMU image (with unique `NERVES_SERIAL_NUMBER`), it joins the same Erlang cluster as the Phoenix node (provided networking allows — documented with bridge networking or host routing).
- Appears in dashboard as "Nerves (real QEMU)" with extra metadata (firmware version from `:application`, uptime, etc.).

### 6.2 ESP32 Simulator Nodes (C)

**Reality Check (Production Honesty):**
- Renode's Xtensa + peripheral support in 2026 is still insufficient for a full ESP-IDF WiFi + LwIP + MQTT stack. We will **not** claim Renode as primary for the ESP32 path.
- Primary simulation path: **Espressif QEMU** (with WiFi emulation fork when needed).
- Secondary flashy path for video/demo: **Wokwi** (browser-based, gorgeous, real WiFi simulation, can connect to your local Mosquitto via a simple WebSocket-to-TCP bridge or public broker + port forward for recording).

**What we ship:**
- Complete, clean, well-commented ESP-IDF v5.4+ project that:
  - Connects to WiFi (or QEMU simulated WiFi)
  - Establishes MQTT connection with LWT, birth certificate, clean session=false
  - Publishes telemetry JSON at configurable interval
  - Subscribes to command topics and acts on `water_now`, `set_auto_mode`, `reboot`, `factory_reset`
  - Uses FreeRTOS tasks + queue for clean architecture
- `scripts/start-esp32-qemu.sh` that uses the espressif Docker image + QEMU to run one instance (device_id passed via menuconfig or env).
- Documentation: "To run on real hardware: `idf.py build flash monitor` on any ESP32 devkit (cheap and impressive in videos)."

This is actually **stronger** for a portfolio than pretending Renode works — it shows you did the research and chose the right tool.

---

## 7. Dashboard Features & LiveView Vision (Flashy but Production Grade)

**Core Experience Goals:**
- Feels like a real industrial control room / modern SaaS IoT console.
- Every action is instant (optimistic + confirmed).
- No page reloads. Everything streams.

**Main Sections (single LiveView for simplicity, or multiple tabs/components):**

1. **Top Navbar**
   - Logo + "Fleet Console"
   - Cluster status pills: "BEAM Nodes: 4/5" "MQTT Clients: 7" "Msg rate: 142/s"
   - Theme toggle (dark is default, plant-green accents)
   - "Add Simulated Device" button (opens nice daisyUI modal)

2. **Device Grid** (responsive, 1–4 columns)
   - Reusable `DeviceCard` function component or LiveComponent.
   - Header: Device name + `nerves` / `esp32` badge + colored status dot + "last seen".
   - Four metric rows with:
     - Soil Moisture: large % number + animated horizontal progress bar (green → yellow → red)
     - Temperature: value + color (blue→orange)
     - Humidity: value + simple bar
     - Battery: % + icon (lightning when charging simulation)
   - Valve state: big visual (pipe + droplet or LED), "Water Now" button (primary action), "Auto Mode" toggle.
   - Footer row: "Simulate Low Battery", "Kill Node" (destructive, red, with confirmation), "View Logs" (opens side panel for that device).

3. **Right Sidebar or Bottom Panel**
   - **Cluster Health** (real metrics):
     - Erlang node list with ping latency (use `:erlang.monitor_node` + timing)
     - MQTT bridge health (connected? reconnect count, last error)
     - Synthetic "command roundtrip" measurement button
   - **Live Event Log** (most impressive part):
     - `stream(:events, ...)` with `phx-update="stream"`
     - Color-coded: green telemetry, blue command sent, purple node joined, orange warning, red error.
     - Timestamp + device + short description + expandable JSON payload.
     - Auto-pauses on scroll, "Resume" button.

4. **Global Controls**
   - "Water All (Auto)" / "Emergency Stop All Valves"
   - "Spawn 3 More Random Devices"
   - "Export Telemetry CSV" (simple, generates on the fly)

**Technical Polish:**
- All sensor numbers use `<.live_number>` component that does smooth count-up animation via JS hook.
- Progress bars use CSS transitions + LiveView `push_event` for value changes.
- Device cards have subtle "pulse" animation on new telemetry (class `animate-pulse` temporarily via `phx-feedback-for` or JS).
- Error boundaries and graceful degradation if MQTT bridge dies.
- Full keyboard support (arrow keys to select cards, space to water).

---

## 8. One-Command Demo Strategy (`make demo` / `./scripts/start-demo.sh`)

**Requirements for "impressive in 60 seconds":**
- Works on a fresh Mac/Linux machine with Docker + Elixir installed (or provides a Devcontainer).
- No manual `mix deps.get`, no editing files.
- Starts 4–6 devices automatically (mix of Nerves-style and ESP32-style simulators).
- Real MQTT traffic visible (user can open MQTT Explorer).
- Optional: launches a second terminal with `observer` attached to the cluster.

**Implementation Outline:**
1. `make demo` calls `scripts/start-demo.sh`.
2. Script:
   - Checks prerequisites (Docker, docker compose, elixir 1.18+, make).
   - `docker compose up -d mosquitto` (with healthcheck).
   - `cd dashboard && mix deps.get && mix assets.setup` (if needed).
   - Exports `MQTT_HOST=localhost` etc.
   - Starts the Phoenix server in background (or foreground with tmux/screen if available).
   - Launches 2 Nerves sims + 2 ESP sims as background jobs or via a small "sim_host" supervisor that the dashboard can also talk to.
   - Waits for port 4000, then `open http://localhost:4000` (or xdg-open).
   - Prints beautiful banner with instructions: "Press 'a' in the UI to add more devices. Watch the event log. Try killing a node."

**Advanced target:** `make demo-distributed` starts two extra `iex` nodes in separate processes that join via libcluster and appear as "real" distributed Nerves devices.

**Docker Compose services (Phase 2+):**
- `mosquitto`
- `dashboard` (optional, for fully containerized)
- `nerves-sim-1`, `nerves-sim-2` (Elixir releases or `mix run --no-halt`)
- `esp-sim-1` (if we containerize the C binary — possible but complex)

---

## 9. Refined Development Phases

**Phase 1 (this document)** — Architecture, naming, structure, versions, diagrams. (Current)

**Phase 2: Core Infrastructure (Foundation)**
- `mix phx.new` Phoenix 1.8 app with LiveView + Tailwind 4 + daisyUI.
- Add `libcluster`, `emqtt`.
- Implement `MqttBridge` (supervised, robust reconnection, birth certificates).
- Basic `FleetState` + ETS device table.
- Dockerfile + docker-compose with Mosquitto + healthchecks.
- First two simulator modules (Nerves + ESP32 logic) that publish realistic data.
- "Hello World" LiveView that shows raw device list updating.
- Initial libcluster Gossip config that works in Docker and localhost.

**Phase 3: Feature Implementation (The Wow)**
- Full beautiful dashboard with cards, progress, controls.
- All device actions wired (`water_now` actually changes moisture physics and publishes command).
- Dynamic device spawning + termination.
- Cluster health panel with real Erlang metrics + synthetic latency.
- Live event log with streams.
- "Kill Node", "Low Battery", "Toggle Auto" fully working.
- Optional: one real Nerves QEMU node + one ESP32 QEMU instance documented and runnable via scripts.
- Optimistic UI + confirmation + error states.

**Phase 4: Full Running Demo & Polish (Portfolio Ready)**
- `make demo` that truly impresses in < 90 seconds.
- README with:
  - Architecture diagram (Mermaid rendered)
  - 3–5 minute demo video (YouTube unlisted or .mp4 in repo)
  - Step-by-step setup for "I have 30 minutes"
  - "How it would work on real hardware" section
  - Production notes (how to add auth, persistence, OTA, etc.)
- Docker Compose fully working for the entire stack.
- CI that at least compiles the C and Elixir code + runs tests.
- Optional but high-value: simple historical persistence (Ecto + SQLite or Postgres) + a tiny chart on each card.
- Code quality: Dialyzer, Credo strict, 90%+ test coverage on core modules, ExDoc.
- GitHub: nice topics, description, social preview image (we can generate one).

---

## 10. Risks & Mitigations (Production Thinking)

| Risk                                      | Impact | Mitigation |
|-------------------------------------------|--------|------------|
| Renode ESP32 WiFi/MQTT not viable         | High   | Documented pivot to Espressif QEMU + Wokwi for demo; real C code still ships |
| Distributed Erlang networking in Docker   | Medium | Provide working Gossip + fallback static peer list; heavy documentation |
| Demo feels "fake" if all simulators live in Phoenix | Medium | Offer separate-node start mode + real QEMU instructions; label devices clearly ("Simulated Nerves Node running in BEAM") |
| QEMU images too heavy for casual users    | Medium | Make full QEMU optional ("Advanced" section). Default demo is pure Elixir + MQTT |
| UI perf with 50+ devices                  | Low    | Use `stream` + `phx-update="ignore"` on static parts + virtual scrolling if needed |
| MQTT message loss / ordering in demo      | Low    | QoS 1, clean code, idempotent handlers |
| Recruiters don't understand hybrid value  | Low    | Excellent README + video that explicitly calls out "This is why you hire someone who knows both worlds" |

---

## 11. Immediate Next Steps (Once Approved)

1. User approves this plan (or requests specific changes).
2. We initialize the GitHub repo properly (rename folder if needed, `git init` if not already the target).
3. Phase 2 kickoff: `mix phx.new dashboard --live --install` inside the structure + first commits.
4. We create a living `ARCHITECTURE.md` and the first Mermaid diagram.
5. We implement the MQTT bridge + two simulators + minimal LiveView in tight, reviewable PRs (or directly if you prefer).

---

## 12. Appendices (for completeness)

- Mermaid diagram source will live in `diagrams/architecture.mmd`
- Full MQTT topic + payload JSON schema will be in `docs/MQTT_TOPICS.md`
- Physics model equations (moisture, temp, battery) will be documented with tests in `plant_physics_test.exs`

---

**This plan is intentionally detailed and production-minded.** It positions the project as a genuine portfolio centerpiece that demonstrates senior-level skills across the full stack: real-time web, distributed systems, embedded C, simulation fidelity, developer experience, and documentation.

Ready for your review and approval. What would you like to change, add, or clarify before we begin Phase 2?