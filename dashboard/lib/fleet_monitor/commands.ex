defmodule FleetMonitor.Commands do
  @moduledoc """
  Thin facade for publishing commands from the LiveView / UI to devices.

  All commands ultimately flow through `FleetMonitor.MqttBridge` so they are
  visible on the MQTT bus (for external tools, logging, and future real devices).
  For local simulators we also broadcast on the internal PubSub topic
  `"fleet:commands"` so they react with near-zero latency (this is the hybrid
  superpower of the architecture).

  Public functions in this module are the canonical way the UI triggers actions.
  They are intentionally simple — they just format the payload and delegate.

  See `DESIGN.md` → "Command & Control Flow" for the full picture, including
  how simulators react and how optimistic UI + telemetry reconciliation works.

  @phase 3
  """

  @doc """
  Request a device to open its valve for a period of time.

  The actual duration enforcement, physics update, and status feedback are
  handled by the target simulator (see `NervesPlant` / `Esp32Plant`).

  ## Parameters
  - `device_id` — target device (e.g. "nerves-001")
  - `duration_ms` — how long the valve should stay open (default 5000)

  This goes over MQTT (and PubSub for local sims).
  """
  def water_now(device_id, duration_ms \\ 5000) when is_binary(device_id) do
    FleetMonitor.MqttBridge.publish_command(device_id, "water_now", %{
      "duration_ms" => duration_ms
    })
  end

  @doc """
  Enable or disable automatic valve control on a device.

  When enabled, the simulator will use `PlantPhysics.auto_valve_state/4`
  (hysteresis) on every tick.

  ## Parameters
  - `device_id`
  - `enabled` — boolean
  """
  def set_auto_mode(device_id, enabled) when is_binary(device_id) and is_boolean(enabled) do
    FleetMonitor.MqttBridge.publish_command(device_id, "set_auto_mode", %{
      "enabled" => enabled
    })
  end

  @doc """
  Force a device into a low-battery state for demo / testing purposes.

  The simulator reacts by rapidly draining its battery value and publishing
  the new state (which the UI and event log will reflect).
  """
  def simulate_low_battery(device_id) when is_binary(device_id) do
    FleetMonitor.MqttBridge.publish_command(device_id, "simulate_low_battery", %{})
  end

  @doc """
  Lightweight side-effect-free "ping" for the hybrid roundtrip latency probe.

  Used by the improved per-device Probe feature in FleetConsoleLive / DeviceCard.
  - Calls through MqttBridge (visible on wire, works for future remote devices).
  - Simulators respond with an immediate telemetry publish (authoritative confirmation).
  - No changes to valve, auto_mode, battery, or physics state.
  - Enables path detection (direct via DeviceManager.lookup_pid vs mqtt) and
    educational measurement of end-to-end confirmation latency.

  Intentionally unauthenticated demo surface (allow-list guarded). See LiveView allow-list + DESIGN.md.
  """
  def ping(device_id) when is_binary(device_id) do
    FleetMonitor.MqttBridge.publish_command(device_id, "ping", %{})
  end

  @doc """
  Set the low/high moisture thresholds used by the auto-irrigation logic.
  Values are percentages (0-100). The simulator will clamp low < high.
  """
  def set_moisture_thresholds(device_id, low, high) when is_binary(device_id) do
    FleetMonitor.MqttBridge.publish_command(device_id, "set_moisture_thresholds", %{
      "low" => low,
      "high" => high
    })
  end

  @doc """
  Immediately close the valve / stop any active water pulse.

  Useful for cancelling a "Water Now" command early from the UI.
  """
  def stop_water(device_id) when is_binary(device_id) do
    FleetMonitor.MqttBridge.publish_command(device_id, "stop_water", %{})
  end

  @doc """
  Kill / remove a device.

  This is **not** sent as an MQTT command to the device. Instead it is handled
  by `DeviceManager.stop_device/1`, which coordinates LWT/retained offline status,
  FleetState removal, and actual supervisor termination.

  The function exists here mainly for API completeness and to give a clear
  error message if someone tries to treat "kill" like a regular device command.
  """
  def kill(_device_id), do: {:error, :use_device_manager}

  @doc """
  Set how often the device reports full telemetry when the valve is closed / in normal auto mode.

  `interval_ms` — milliseconds between reports when not actively watering.
  When the valve is open (Water Now / active pulse), the device reports at 4x per minute for good visibility.
  """
  def set_telemetry_interval(device_id, interval_ms)
      when is_binary(device_id) and is_integer(interval_ms) do
    FleetMonitor.MqttBridge.publish_command(device_id, "set_telemetry_interval", %{
      "interval_ms" => interval_ms
    })
  end
end
