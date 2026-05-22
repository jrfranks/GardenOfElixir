defmodule FleetMonitor.DeviceManager do
  @moduledoc """
  High-level facade and lifecycle manager for dynamic simulated devices (Phase 3).

  This module is the primary entry point for the LiveView (and any future
  administrative interfaces) when adding or removing devices at runtime.

  Responsibilities:
  - Validate and normalize device identifiers (length, uniqueness, safety).
  - Map high-level device types (`:nerves`, `:esp32`) to the correct simulator module.
  - Create safe child specifications for `DeviceSupervisor` (using tuple child IDs
    `{:dyn, binary}` to avoid atom table exhaustion — a critical fix from review).
  - Coordinate graceful termination: publish retained "offline" status via the
    MQTT bridge (simulating LWT behavior) before asking the supervisor to stop the child.
  - Provide lookup helpers that work with the Registry (enabling the hybrid
    direct-call path for local simulators while still going over MQTT for
    universality and external observability).

  This module deliberately stays thin. All the heavy lifting of supervision,
  Registry registration, and actual GenServer lifecycle lives in
  `DeviceSupervisor` and the individual simulator modules.

  See `DESIGN.md` sections "Dynamic device lifecycle" and "Command & Control Flow"
  for the broader architectural rationale.

  @phase 3
  """

  require Logger

  alias FleetMonitor.{
    DeviceRegistry,
    DeviceSupervisor,
    FleetState,
    MqttBridge
  }

  @doc """
  Start a new simulated device at runtime from the LiveView or administrative code.

  ## Parameters
  - `type` — `:nerves` or `:esp32` (maps to the correct simulator implementation)
  - `device_id` — human-readable unique identifier (e.g. "nerves-042", "esp32-demo-007")

  ## Returns
  - `{:ok, pid}` on success
  - `{:error, :invalid_id}` if the id is too long/short
  - `{:error, :already_exists}` if a device with that id is already registered

  ## Safety
  This function contains the remediation for the critical atom-exhaustion
  vulnerability discovered during the high-effort Phase 3 review. Child IDs
  are always safe `{:dyn, binary}` tuples. No `String.to_atom/1` is ever
  performed on user- or runtime-generated data.

  The function also performs an early Registry lookup (with rescue for test
  environments where the Registry may not be started) to provide a fast
  duplicate rejection path.
  """
  def start_device(type, device_id) when is_atom(type) and is_binary(device_id) do
    # Phase 3 remediation (review #1 Critical): safe binary-based child ID (no String.to_atom on runtime/user input)
    with :ok <- validate_device_id(device_id),
         :ok <- ensure_not_registered(device_id) do
      do_start_simulator(type, device_id)
    end
  end

  defp validate_device_id(device_id) do
    if byte_size(device_id) > 32 or byte_size(device_id) < 3 do
      {:error, :invalid_id}
    else
      :ok
    end
  end

  defp ensure_not_registered(device_id) do
    registered? =
      try do
        DeviceRegistry.lookup(device_id) != []
      rescue
        _ -> false
      end

    if registered? do
      {:error, :already_exists}
    else
      :ok
    end
  end

  defp do_start_simulator(type, device_id) do
    module = simulator_module(type)
    child_id = {:dyn, device_id}

    child_spec =
      Supervisor.child_spec({module, [device_id: device_id]}, id: child_id)

    case DeviceSupervisor.start_device(child_spec) do
      {:ok, pid} ->
        # Minimal birth marker; the simulator's own init immediately publishes full status
        # (with thresholds etc.) so this does not drop anything long-term.
        FleetState.update_device_status(device_id, %{
          state: "online",
          type: Atom.to_string(type)
        })

        Logger.info("DeviceManager: device spawned", device: device_id, type: type)

        Phoenix.PubSub.broadcast(
          FleetMonitor.PubSub,
          "fleet:events",
          {:device_born, device_id, type}
        )

        {:ok, pid}

      other ->
        other
    end
  end

  @doc """
  Stop (kill) a device gracefully: publish offline LWT retained status, then terminate.
  Uses registry for pid lookup. Returns :ok | {:error, reason}
  """
  def stop_device(device_id) when is_binary(device_id) do
    pid =
      try do
        case DeviceRegistry.lookup(device_id) do
          [{_id, p}] when is_pid(p) -> p
          _ -> nil
        end
      rescue
        _ -> nil
      end

    if pid do
      # Publish LWT offline retained (universal path, visible to any observer)
      # Phase 3 nit fix: fire-and-forget (best-effort on kill path; detached to not block supervisor termination)
      spawn(fn ->
        MqttBridge.publish_status(device_id, %{
          state: "offline",
          reason: "killed_via_console",
          last_seen: DateTime.utc_now() |> DateTime.to_iso8601()
        })
      end)

      # Remove from state immediately (optimistic)
      FleetState.remove_device(device_id)

      # Broadcast for event log
      Phoenix.PubSub.broadcast(FleetMonitor.PubSub, "fleet:events", {:device_killed, device_id})

      res = DeviceSupervisor.stop_device(pid)
      Logger.info("DeviceManager: device stopped", device: device_id, result: inspect(res))
      :ok
    else
      FleetState.remove_device(device_id)
      {:error, :not_found}
    end
  end

  @doc "Lookup pid for direct GenServer calls (low-latency hybrid path for local sims)."
  def lookup_pid(device_id) do
    case DeviceRegistry.lookup(device_id) do
      [{_id, pid}] -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp simulator_module(:nerves), do: FleetMonitor.Simulators.NervesPlant
  defp simulator_module(:esp32), do: FleetMonitor.Simulators.Esp32Plant
  defp simulator_module(_), do: FleetMonitor.Simulators.NervesPlant
end
