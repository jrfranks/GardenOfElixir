# Design Document — elixir-iot-fleet-monitor

**Project:** A high-quality, visually impressive, hybrid IoT fleet monitoring system showcasing advanced Elixir + embedded systems skills.

**Status:** Phase 3 ("The Wow") complete. Phase 4 (polish, video, production notes) planned.

**Audience:** Engineers and maintainers new to the project, contributors, and anyone evaluating the codebase for portfolio or hiring purposes.

---

## 1. Project Goals & Philosophy

### Primary Goals
- Create a **portfolio-grade open-source project** that demonstrates senior-level capability across the full stack:
  - Real-time web (Phoenix LiveView)
  - Distributed systems (libcluster + Phoenix.PubSub)
  - Embedded simulation (realistic physics + command handling)
  - Heterogeneous device communication (MQTT as the universal bus)
  - Production-grade patterns (supervision, reconnection, safe parsing, structured logging, resource bounding)
- Deliver a **visually and interactively impressive "Fleet Console"** that feels like a real industrial IoT control room when you run `make demo`.
- Clearly illustrate the **power of the hybrid architecture**: MQTT for cross-language / constrained devices + native Distributed Erlang for Elixir/Nerves nodes (the "right tool for the job").

### Non-Goals (Scope Boundaries)
- This is **not** a production fleet management system (see NervesHub for that).
- Real hardware (ESP32 on devkits, Nerves on actual boards) and full QEMU/OTA flows are documented but deferred to later work or external demos.
- Authentication, multi-tenancy, persistence, and OTA are explicitly Phase 4 / future concerns.
- The system is intentionally "demo-first" but with production *patterns* (not production security surface).

### Design Philosophy
- **Comment for the next engineer** (and your future self). Every non-obvious decision gets a comment.
- **Smallest viable change** that delivers the required behavior while preserving existing invariants.
- **Telemetry is the source of truth**. Optimistic UI is for feel only; the bridge + simulators + `FleetState` (ETS) always win.
- **Hybrid by design**. MQTT is the lingua franca. Distributed Erlang is the performance/superpower path for BEAM nodes.
- **Simulated but realistic**. The plant physics engine is pure, deterministic (where intended), and actually drives behavior.

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Fleet Console (Phoenix LiveView)         │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  FleetConsoleLive (orchestrator)                          │  │
│  │  - Device grid + DeviceCard components (gauges, controls) │  │
│  │  - Live event stream (phx-update="stream")                │  │
│  │  - Cluster health panel + roundtrip probe                 │  │
│  │  - Optimistic updates + reconciliation from FleetState    │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  DeviceManager + DeviceSupervisor (DynamicSupervisor)           │
│  FleetState (ETS + PubSub subscriber, richer status)            │
│  Commands (thin facade)                                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼  PubSub ("fleet:telemetry", "fleet:commands", "fleet:events", "fleet:status")
┌─────────────────────────────────────────────────────────────────┐
│                        MqttBridge (GenServer)                   │
│  - Single supervised emqtt client                               │
│  - Exact v1/dt/cmd/status/evt topic schema (§3.1)               │
│  - Per-metric + aggregate dual publishing (wire fidelity)       │
│  - LWT, retained birth/death, safe parsing, reconnection        │
│  - Fans out to Phoenix.PubSub (distributed)                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼  Mosquitto (MQTT broker)
         ┌────────────────────────────────────────────┐
         │                                            │
         ▼                                            ▼
┌──────────────────────┐                   ┌──────────────────────┐
│ NervesPlant /        │                   │ ESP32Plant /         │
│ Esp32Plant simulators│                   │ real ESP32 devices   │
│ (Elixir GenServers)  │                   │ (C / ESP-IDF)        │
│ - plant_physics      │                   │ - same topic schema  │
│ - command handlers   │                   │ - will use MQTT      │
│ - publish via bridge │                   │                      │
└──────────────────────┘                   └──────────────────────┘
```

**Key Insight**: Simulators (and future real Nerves nodes) can also participate in the BEAM cluster for ultra-low-latency direct calls, while still using MQTT for universality and external observability.

---

## 3. Core Subsystems & Design Decisions

### 3.1 plant_physics (Pure Functional Core)
**Location**: `dashboard/lib/fleet_monitor/plant_physics.ex`

- Completely pure functions (no side effects, easy to test and reason about).
- Models realistic plant dynamics:
  - Exponential moisture decay modulated by temperature.
  - Hysteresis-based auto-valve logic (prevents chattering).
  - Battery drain that increases when the valve is open.
  - Deterministic daily temperature cycle (seeded by device_id for reproducibility).
- Used by **both** simulator types — this is intentional for consistency.

**Why pure?** Testability, reproducibility, and to make the "simulation engine" a first-class, reviewable artifact.

### 3.2 MqttBridge (The Universal Bus Adapter)
**Location**: `dashboard/lib/fleet_monitor/mqtt_bridge.ex`

- The only place that talks directly to Mosquitto.
- Enforces the exact topic schema from the Phase 1 plan (`v1/dt/fleet/plant/{id}/{metric}` etc.).
- Dual publishing strategy (per-metric on the wire for external tools + aggregate for internal PubSub efficiency).
- Hardened against bad payloads (learned from earlier review findings).
- LWT + retained messages for professional "birth certificate" behavior.

**Design decision**: Keep the bridge relatively dumb and reliable. All business logic lives in simulators or the LiveView layer.

### 3.3 FleetState + Device Lifecycle
- `FleetState`: In-memory (ETS) source of truth for the current fleet view. Subscribes to PubSub and merges telemetry + richer status (`valve_open`, `auto_mode`).
- `DeviceSupervisor` + `DeviceManager`: DynamicSupervisor-based runtime device management (Phase 3).
  - Child IDs use safe `{:dyn, binary_id}` tuples (fixed a critical `String.to_atom` atom-exhaustion issue found in review).
  - Graceful termination publishes retained "offline" status (LWT simulation).

**Why ETS + PubSub?** Fast concurrent reads from the LiveView while keeping a single writer (the bridge and simulators).

### 3.4 Command & Control Flow (The Heart of Interactivity)
1. User action in LiveView (`handle_event`)
2. Optimistic local update (for immediate feel) + `FleetMonitor.Commands.*`
3. `Commands` → `MqttBridge.publish_command` (goes out over MQTT + internal PubSub broadcast on `"fleet:commands"`)
4. Target simulator receives via PubSub subscription (local sims) or will receive via its own MQTT client (future real devices).
5. Simulator updates internal state, affects physics, immediately publishes fresh telemetry.
6. Telemetry round-trips through the bridge → PubSub → `FleetState` (authoritative) → LiveView (reconciliation wins).

This design makes the "Water Now" button actually do something observable in the physics, while still being safe and observable via external MQTT tools.

The improved roundtrip latency probe (see FleetConsoleLive + DeviceCard + Commands.ping) demonstrates the hybrid value proposition directly in the UI:
- Global "Probe Random" + per-device ⏱ buttons in every card footer.
- `Commands.ping/1` is a zero-side-effect command (explicit handler in both sims that only triggers telemetry publish).
- Path detection via `DeviceManager.lookup_pid/1` labels results as `:direct` (local Erlang/PubSub, sub-10 ms typical) or `:mqtt`.
- Timing is from send until authoritative telemetry confirmation (not just command echo).
- Pending map + timeout + cleanup on kill prevent state leaks.
- Badges in cards and "Last probe" in Cluster Health make the architecture's latency advantage immediately obvious during `make demo`.

### 3.5 UI Architecture (LiveView + Components)
- `FleetConsoleLive`: Coordinator / orchestrator. Owns streams, cluster state, optimistic overlays, and reconciliation logic.
- `DeviceCard`: Pure function component (no LiveComponent). Uses Tailwind + CSS for gauges and transitions. Deliberately avoids extra JS dependencies for Phase 3.
- Heavy use of `stream/3` for the event log (performance + idiomatic LiveView).
- "Telemetry is truth" reconciliation on every relevant `handle_info`.

**Why pure function components?** Simpler mental model, easier testing, and sufficient for the current interactivity needs. LiveComponents can be introduced later if card-level state or heavy animation is required.

---

## 4. Key Technology Choices & Rationale

| Area                  | Choice                          | Why |
|-----------------------|---------------------------------|-----|
| MQTT client (bridge)  | `emqtt`                         | Battle-tested, excellent reconnection, MQTT 5 features, high performance. |
| Device communication  | MQTT (universal) + PubSub (local BEAM) | Universality for ESP32/C + speed for Elixir nodes. |
| Device state          | ETS (FleetState) + internal GenServer state (sims) | Fast reads + encapsulation of physics. |
| Dynamic devices       | DynamicSupervisor + Registry    | Standard OTP, clean supervision, unique naming. |
| Gauges / visuals      | Pure Tailwind + CSS             | No extra dependencies, fast, sufficient for impressive demo. |
| Event log             | `LiveView.stream/3`             | Idiomatic, efficient, built-in diffing. |
| Parsing safety        | Guarded `case Integer.parse` / `Float.parse` with fallbacks | Learned the hard way in Phase 2 reviews. |
| Child IDs             | `{:dyn, binary}` tuples         | Avoids atom table exhaustion (critical fix from review). |

---

## 5. Directory & Module Layout (Monorepo)

```
elixir-iot-fleet-monitor/
├── dashboard/                  # Phoenix 1.8 LiveView console
│   ├── lib/fleet_monitor/
│   │   ├── plant_physics.ex           # Pure simulation engine
│   │   ├── mqtt_bridge.ex             # MQTT ↔ PubSub adapter (core)
│   │   ├── fleet_state.ex             # Authoritative in-memory fleet view
│   │   ├── device_supervisor.ex       # DynamicSupervisor
│   │   ├── device_manager.ex          # High-level spawn/kill facade
│   │   ├── commands.ex                # Command helpers
│   │   └── simulators/                # Two realistic device implementations
│   ├── lib/fleet_monitor_web/
│   │   ├── live/fleet_console_live.ex # The main UI orchestrator
│   │   └── components/device_card.ex  # Reusable card (gauges + controls)
│   └── ...
├── nerves/plant_monitor/       # Stub for real Nerves firmware (future)
├── esp32/plant_monitor/        # Stub for real ESP-IDF firmware (future)
├── shared/                     # Future extraction point for common logic
├── scripts/start-demo.sh
├── docker-compose.yml + Dockerfile
├── Makefile
└── docs/
    ├── PHASE1_ARCHITECTURE_AND_PLAN.md
    ├── PHASE3_FEATURE_IMPLEMENTATION_PLAN.md
    └── (this) DESIGN.md
```

---

## 6. Important Invariants & Safety Properties

- **No unsafe parsing of external data** on hot paths (all `parse` calls are guarded).
- **Telemetry always wins** over optimistic UI state.
- **No user-controlled atoms** (fixed during Phase 3 review).
- **Dynamic devices are first-class** and can be added/removed at runtime without leaking supervision or registry entries.
- **The wire schema is authoritative** (`v1/dt/fleet/plant/...` per the original plan). The internal aggregate path is an optimization only.
- **All simulators use the same physics** (consistency between "Nerves" and "ESP32" flavors).

---

## 7. How to Extend the System (Guidance for Future Engineers)

- **New sensor type**: Add to `plant_physics.sample_sensors/1` and the per-metric publishing logic in the bridge. Update the DeviceCard gauges.
- **New command**: Add a handler in `Commands`, wire a button in the LiveView + DeviceCard, implement reaction in the simulators, and publish a status/feedback telemetry.
- **Real Nerves device**: Build the firmware using the same topic schema and `emqtt` (or `tortoise`). It can optionally join the BEAM cluster for direct calls.
- **Real ESP32**: Implement the same MQTT topics + JSON payloads in ESP-IDF. The console will work without changes.
- **Persistence / historical charts**: Add Ecto + a time-series store in Phase 4. `FleetState` can remain the hot cache.

---

## 8. Known Limitations & Future Work (Phase 4+)

- No authentication or multi-user support (demo-only surface is intentionally open with warnings).
- Event log is bounded but in-memory only.
- No historical data or charts yet.
- Real hardware/QEMU flows and OTA are documented but not fully exercised in the demo.
- Some simulator logic is still duplicated between the two flavors (can be centralized later).

---

## 9. References

- `docs/PHASE1_ARCHITECTURE_AND_PLAN.md` — Original architecture and communication model.
- `docs/PHASE3_FEATURE_IMPLEMENTATION_PLAN.md` — Detailed Phase 3 execution plan.
- `AGENTS.md` (in `dashboard/`) — Project-specific coding guidelines for this Phoenix 1.8 app.

---

*This document is intended to be living. Update it when major architectural decisions are made.*

**Maintained with the same rigor as the code itself.**