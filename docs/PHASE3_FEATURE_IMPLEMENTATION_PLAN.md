# Phase 3: Feature Implementation Plan — "The Wow"

**Status:** Ready for execution  
**Predecessor:** Phase 2 Core Infrastructure (complete and reviewed)  
**Based on:** `docs/PHASE1_ARCHITECTURE_AND_PLAN.md` (Section 9 Phase 3 bullets)  
**Current Codebase State:** Working Phase 2 foundation with minimal table LiveView

---

## 1. Goals for Phase 3

Phase 3 transforms the solid but minimal Phase 2 proof-of-concept into the **visually impressive, interactive "Fleet Console"** that makes the project a standout portfolio piece.

Primary objectives:
- Beautiful, modern, production-like dashboard that feels like a real industrial IoT control room.
- Every major action from the original vision works end-to-end:
  - "Water Now"
  - "Toggle Auto Mode"
  - "Simulate Low Battery"
  - "Kill Node" (graceful simulator termination with LWT)
- Dynamic device lifecycle (add/remove simulated devices at runtime).
- Live event log that feels alive.
- Cluster health panel showing real Erlang + libcluster metrics.
- Optimistic UI with proper confirmation/error handling.
- All while staying strictly within the "simulated hybrid fleet" scope (no real QEMU hardware yet — that stays Phase 4).

Success looks like: a recruiter or hiring manager can run `make demo`, immediately feel "this is impressive," and understand why the hybrid MQTT + Distributed Erlang architecture is powerful.

---

## 2. Current State (What Phase 2 Gave Us)

**Strengths we build on:**
- `plant_physics.ex` (pure, tested, shared by both simulator types)
- `MqttBridge` (correct handlers, LWT, dual per-metric + aggregate publishing, safe parsing)
- `FleetState` (ETS-backed, PubSub subscriber)
- Two simulator GenServers with internal state (`valve_open`, etc.)
- Minimal but working `FleetConsoleLive` (table + telemetry flow)
- Command stub in `FleetMonitor.Commands`
- Working `make demo` + Docker support

**Limitations / things we will evolve:**
- LiveView is a raw table (intentionally minimal)
- No device cards, gauges, or controls
- Simulators only react to `:tick` (no command handling yet)
- No DynamicSupervisor — devices are statically started in `application.ex`
- No event log, no optimistic updates, no "Kill Node"
- `FleetState` stores flat metrics; richer per-device state (valve, auto_mode, etc.) is only inside simulators

---

## 3. UI/UX Vision & Component Strategy

### Overall Look & Feel
- Dark industrial theme (zinc + emerald accents, consistent with Phase 2)
- Responsive grid of **Device Cards** (1–4 columns depending on viewport)
- Prominent **Cluster Health** sidebar or top bar
- **Live Event Log** at the bottom or right side (stream-based, auto-scrolling)
- Global actions ("Water All", "Emergency Stop") + "Add Simulated Device" button

### Device Card (the star of Phase 3)
Each card should feel alive and controllable:

- Header: Device ID + type badge (Nerves blue / ESP32 amber) + online status dot + last seen
- Four metric sections with **nice visual gauges**:
  - Soil Moisture: large % + animated horizontal or radial progress bar (color: green → yellow → red)
  - Temperature: value + subtle color shift
  - Humidity: value + bar
  - Battery: value + icon (lightning bolt when recently watered)
- **Valve / Control section**:
  - Current valve state (visual pipe + droplet or LED)
  - Big primary action: **"Water Now"** button (with duration input or sensible default)
  - Toggle: **Auto Mode** (on/off) with current threshold hint
- Footer actions (smaller, destructive styling):
  - "Simulate Low Battery"
  - "Kill Node" (red, with confirmation)

**Technical choices for gauges:**
- Prefer **pure Tailwind + CSS** (conic gradients, transitions, `progress` or custom divs) + daisyUI where it helps.
- Only introduce a small JS hook if we need smooth count-up numbers or canvas sparkline. Keep dependency surface low for Phase 3.

### Live Event Log
- Uses `Phoenix.LiveView.stream/3` + `phx-update="stream"`
- Color-coded entries:
  - Green: telemetry received
  - Blue: command sent
  - Purple: device joined / born
  - Orange: warning (low battery, etc.)
  - Red: device killed / offline (LWT)
- Shows device + short human message + timestamp
- Clickable to expand JSON payload
- "Pause / Resume" and "Clear" controls

### Cluster Health Panel
Real metrics that demonstrate the BEAM side:
- Erlang nodes connected (`Node.list()` + `Node.monitor`)
- Message rate (simple counter or telemetry poller)
- Synthetic command roundtrip latency (button that sends a ping command and measures reply)
- libcluster topology status (if we activate the cluster child in Phase 3)

---

## 4. Data & State Architecture

### Evolution of `FleetState`
We will extend it to hold richer per-device state:

```elixir
%{
  id: "...",
  type: "nerves" | "esp32",
  metrics: %{soil_moisture: ..., ...},
  status: %{valve_open: bool, auto_mode: bool, ...},
  last_seen: ts,
  online: bool
}
```

`FleetState` will also become the source of truth for which devices are currently managed (supporting dynamic add/remove).

### Device Registry + DynamicSupervisor
Introduce:

- `FleetMonitor.DeviceSupervisor` — a `DynamicSupervisor`
- `FleetMonitor.DeviceRegistry` (already exists) will be used more heavily for `{:via, ...}` lookups
- A new process (or the existing `FleetState`) that can start/stop simulator children on demand from the LiveView

When a user clicks "Add Simulated Device", the LiveView will call into a context or a `DeviceManager` that does `DynamicSupervisor.start_child(...)`.

"Kill Node" will call `DynamicSupervisor.terminate_child(...)` (or send a graceful stop message first).

### Command Flow (the heart of interactivity)
1. LiveView button click → optimistic update in assigns + `FleetState`
2. Call `FleetMonitor.Commands.water_now(device_id, duration)`
3. `Commands` → `MqttBridge.publish_command(...)` (goes out over MQTT)
4. The target simulator receives the command (via its own MQTT subscription or via a PubSub forward from the bridge for local sims)
5. Simulator updates its internal state (`valve_open = true` for X seconds)
6. Next tick publishes new telemetry → bridge → PubSub → `FleetState` → LiveView (confirmation)
7. If the device is a "real" clustered Nerves node, the command can also be delivered via direct `GenServer.call` for ultra-low latency (showing the power of the hybrid architecture).

We will make simulators subscribe to command topics (or a `"fleet:commands:#{device_id}"` PubSub topic) so the same path works for both simulated and future real devices.

---

## 5. Specific Implementation Areas

### 5.1 New / Changed Modules (proposed)

**New:**
- `lib/fleet_monitor/device_supervisor.ex`
- `lib/fleet_monitor/device_manager.ex` (or context) — high-level API for spawn/kill
- `lib/fleet_monitor_web/components/device_card.ex` (function component + helpers)
- `lib/fleet_monitor_web/live/fleet_event_log.ex` (or a LiveComponent)
- `lib/fleet_monitor_web/hooks/` (if we need JS for nice gauges/count-up)
- `test/fleet_monitor/commands_test.exs` + integration tests for command roundtrips

**Evolved:**
- `fleet_console_live.ex` — becomes the main orchestrator (much richer `render` + many `handle_event`)
- `fleet_state.ex` — richer device records + `start_device/2`, `stop_device/1`, `send_command/3`
- `nerves_plant.ex` + `esp32_plant.ex` — add `handle_info({:command, action, payload}, state)`
- `mqtt_bridge.ex` — ensure commands are also fanned out via PubSub for local simulators (optional but clean)
- `commands.ex` — flesh out `water_now`, `set_auto_mode`, `simulate_low_battery`, `kill` helpers

### 5.2 LiveView Patterns We Will Use
- Heavy use of **function components** (Phoenix 1.8 style)
- `stream/3` for the event log (critical for performance)
- `assign` + targeted `push_event` for optimistic feedback
- `handle_event` for all button actions
- Possibly one small `LiveComponent` for a device card if isolation becomes valuable (otherwise pure function components + parent state is fine for Phase 3)

---

## 6. Risks & Mitigations Specific to Phase 3

| Risk | Impact | Mitigation |
|------|--------|------------|
| Optimistic updates get out of sync with reality | Medium | Always treat telemetry as source of truth; commands are "requests" |
| DynamicSupervisor + Registry complexity | Medium | Introduce a thin `DeviceManager` facade; write good tests |
| Too many moving parts in one LiveView | Medium | Extract function components aggressively; keep `FleetConsoleLive` as coordinator |
| Gauge / animation performance with 20+ devices | Low | Pure CSS transitions first; only add JS hooks if needed |
| Command delivery latency surprises users | Low | Show "sent" immediately, then "confirmed" when telemetry arrives |
| Killing a device while it is publishing | Low | Use graceful shutdown + monitor in the supervisor |

---

## 7. Verification Criteria — "Phase 3 is Done When..."

- `make demo` shows a beautiful grid of device cards with live gauges and controls.
- Clicking **Water Now** on any device visibly opens the valve (physics changes moisture faster) and the UI updates optimistically then confirms via real telemetry.
- **Toggle Auto Mode** works and the simulator respects the hysteresis logic.
- **Simulate Low Battery** and **Kill Node** work and produce the expected LWT/offline events in the log.
- Live event log scrolls with color-coded, useful entries.
- Cluster health panel shows at least node count and a working roundtrip latency measurement.
- You can dynamically add a new simulated device from the UI and it immediately starts publishing.
- All new code is formatted, has reasonable test coverage on the new command + lifecycle paths, and passes the existing test suite.
- No regressions in the Phase 2 data path or simulator physics.

---

## 8. Suggested Implementation Order (Inside Phase 3)

1. **Foundation** — Evolve `FleetState` + introduce `DeviceSupervisor` + `DeviceManager`. Add command handling skeleton to the two simulators.
2. **Device Card component** — Build the visual card (metrics + gauges) first in isolation, wired to the existing table data.
3. **Wire the first real action** — "Water Now" (optimistic + command + confirmation).
4. **Auto Mode toggle** + richer device status in state.
5. **Live Event Log** (stream) + wiring of status/telemetry events into it.
6. **"Kill Node" + "Low Battery"** (exercises termination + LWT).
7. **Dynamic spawning** from the UI.
8. **Cluster health panel** (real metrics + synthetic latency).
9. **Polish & edge cases** (error states, loading, confirmation messages, keyboard support).
10. **Tests + docs** update.

This order lets us have visible progress early (pretty cards + first working button) while deferring the more complex dynamic lifecycle.

---

## 9. Open Decisions (to be finalized before or during implementation)

- Do we activate the `libcluster` child in Phase 3 (for real distributed Nerves nodes) or keep it commented?
- Exact gauge implementation (pure CSS vs small hook)?
- Should individual device cards be function components or LiveComponents? (current lean: function components + parent state)
- How much per-device command history do we keep (for the log vs per-card)?
- Do we want a "global" command (Water All) in Phase 3?

---

**This document is the authoritative plan for Phase 3.**

Once approved (or after any adjustments you want), we can begin execution — either via another structured `/implement` run with appropriate effort level (likely 3 or 4, given the UI + new logic + dynamic supervisor complexity), or iteratively file-by-file.

Ready when you are. What would you like to adjust or clarify in this Phase 3 plan before we start building the impressive dashboard?