defmodule FleetMonitor.DeviceSupervisor do
  @moduledoc """
  DynamicSupervisor responsible for the supervised lifecycle of all
  runtime-spawned simulated IoT devices (Phase 3).

  This is the actual OTP supervisor that backs the "Add Device" and "Kill Node"
  features in the Fleet Console. It is started permanently from
  `FleetMonitor.Application`.

  Design notes:
  - Strategy is `:one_for_one` — a single simulator crash does not cascade.
  - Children are looked up via `DeviceRegistry` (unique keys) so the LiveView
    and `DeviceManager` can send direct messages when needed (hybrid path).
  - Termination is always coordinated with `DeviceManager` so that a retained
    "offline" status message is published to MQTT (LWT simulation) before the
    child is terminated.

  This module is intentionally minimal. All policy (validation, child_spec
  construction, LWT coordination) lives in `DeviceManager`.

  See `DESIGN.md` section "Dynamic device lifecycle".

  @phase 3
  """

  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a device child under supervision. child_spec is e.g. {NervesPlant, [device_id: id]}"
  def start_device(child_spec) do
    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} = ok ->
        Logger.info("DeviceSupervisor started device", pid: inspect(pid))
        ok

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      other ->
        Logger.warning("DeviceSupervisor start_child failed", error: inspect(other))
        other
    end
  end

  @doc "Terminate a device by its pid (graceful). Manager should also publish LWT offline."
  def stop_device(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc "List all supervised device pids (for health/debug)."
  def which_children do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_id, pid, _type, _mods} -> pid end)
    |> Enum.filter(&is_pid/1)
  end
end
