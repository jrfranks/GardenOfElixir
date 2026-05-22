defmodule FleetMonitor.Simulators.DeviceSimulator do
  @moduledoc """
  Behaviour defining the contract for all plant-monitoring device simulators.

  Both the "Nerves" and "ESP32" simulator implementations (and any future
  variants) conform to this behaviour. This gives the rest of the system
  (DeviceManager, LiveView, tests) a uniform way to interact with devices
  regardless of their internal flavor.

  The two concrete implementations differ mainly in timing, noise, and
  "personality" to make the demo feel like a heterogeneous fleet, while
  sharing the exact same `PlantPhysics` engine for correctness and
  reproducibility.

  See the two implementations in this directory and `DESIGN.md` for details.

  @phase 3 (extracted from earlier simulator work)
  """

  @type device_id :: String.t()
  @type device_type :: :nerves | :esp32

  @type telemetry :: %{
          soil_moisture: float(),
          temperature: float(),
          humidity: float(),
          battery: float()
        }

  @callback start_link(opts :: keyword()) :: GenServer.on_start()
  @callback device_id(pid :: pid()) :: device_id()
  @callback device_type() :: device_type()

  # Optional callback used by some tests / introspection.
  @callback current_telemetry(pid :: pid()) :: telemetry()

  @optional_callbacks current_telemetry: 1
end
