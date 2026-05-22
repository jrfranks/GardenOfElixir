defmodule FleetMonitor do
  @moduledoc """
  FleetMonitor is the main application namespace for the hybrid IoT Fleet Console.

  This module serves as the root for all business logic modules under
  `FleetMonitor.*`. Unlike a typical Phoenix app with many contexts backed
  by a database, this project is a **simulation + real-time dashboard** with:

  - `FleetMonitor.MqttBridge` — the central MQTT ↔ PubSub adapter
  - `FleetMonitor.FleetState` — authoritative in-memory fleet view (ETS)
  - `FleetMonitor.PlantPhysics` — pure simulation engine
  - `FleetMonitor.Simulators.*` — device simulators (Nerves + ESP32 flavors)
  - `FleetMonitor.DeviceManager` / `DeviceSupervisor` — dynamic device lifecycle (Phase 3)
  - `FleetMonitor.Commands` — high-level command facade

  There is no Ecto schema or database in the current implementation
  (persistence is planned for Phase 4).

  See `DESIGN.md` for the full architecture and data flow.
  """
end
