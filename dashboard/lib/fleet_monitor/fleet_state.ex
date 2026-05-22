defmodule FleetMonitor.FleetState do
  @moduledoc """
  Authoritative in-memory view of the current fleet (metrics + rich status).

  This GenServer subscribes to the PubSub topics published by `MqttBridge`
  (`"fleet:telemetry"`, `"fleet:status"`, etc.) and maintains a fast ETS table
  that the LiveView and other processes can read concurrently.

  Responsibilities in Phase 3:
  - Store the latest normalized telemetry for every device.
  - Merge richer per-device status (`valve_open`, `auto_mode`, etc.) coming from
    simulators when they react to commands or make autonomous decisions.
  - Support dynamic devices (add via telemetry birth, remove via `remove_device/1`
    called by `DeviceManager` on kill).
  - Provide a simple query API (`get_all_devices/0`, `get_device/1`, etc.) used
    heavily by `FleetConsoleLive` and the `DeviceCard` component.

  Design notes:
  - ETS is used for read-heavy concurrent access (the LiveView reads on every
    render / handle_info). Writes are serialized through the GenServer.
  - "Telemetry is the source of truth" — richer status is merged on top of
    telemetry records so that the UI always eventually reflects reality.
  - This module is the single place the LiveView should read current device state
    (the LiveView itself keeps a small optimistic overlay for instant feedback).

  See `DESIGN.md` sections on FleetState and the command flow.

  @phase 2 (core) + evolved in Phase 3
  """

  use GenServer
  require Logger

  @table :fleet_state_devices

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Return the current fleet as a map of device_id => device record."
  def get_all_devices do
    :ets.tab2list(@table)
    |> Enum.map(fn {id, data} -> {id, data} end)
    |> Map.new()
  end

  @doc "Return the record for a single device, or nil if unknown."
  def get_device(device_id) do
    case :ets.lookup(@table, device_id) do
      [{^device_id, data}] -> data
      [] -> nil
    end
  end

  @doc """
  Remove a device entirely from FleetState.

  Called by `DeviceManager` when a device is killed (via "Kill Node" or dynamic
  termination). Safe to call if the device is already gone.
  """
  def remove_device(device_id) when is_binary(device_id) do
    # Defensive guard for test environments or shutdown races where the table
    # may not exist yet.
    if :ets.info(@table) != :undefined do
      :ets.delete(@table, device_id)
    end
  end

  @doc """
  Update (or create) the richer per-device status map.

  Used when simulators react to commands (`water_now`, `set_auto_mode`, etc.)
  and want to publish their new internal state (valve_open, auto_mode, etc.)
  without waiting for the next telemetry tick.

  The map is merged into the existing device record so that metrics and status
  stay together.
  """
  def update_device_status(device_id, status) when is_binary(device_id) and is_map(status) do
    GenServer.cast(__MODULE__, {:update_status, device_id, status})
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(FleetMonitor.PubSub, "fleet:telemetry")
    Phoenix.PubSub.subscribe(FleetMonitor.PubSub, "fleet:status")
    Logger.info("FleetState initialized (ETS + PubSub subscriber) — Phase 3 richer state")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:telemetry, device_id, metrics, ts}, state) do
    # "Telemetry is the source of truth" (see DESIGN.md).
    # When fresh metrics arrive we preserve any richer status the device
    # previously reported via command feedback. This is the key reconciliation
    # step that keeps optimistic UI and autonomous simulator decisions in sync.
    base =
      case :ets.lookup(@table, device_id) do
        [{^device_id, existing}] -> Map.take(existing, [:type, :status, :online])
        _ -> %{type: infer_type(device_id), status: %{}, online: true}
      end

    data =
      Map.merge(base, %{
        id: device_id,
        metrics: metrics,
        last_seen: ts,
        online: true
      })

    :ets.insert(@table, {device_id, data})
    {:noreply, state}
  end

  def handle_info({:status, device_id, status}, state) do
    case :ets.lookup(@table, device_id) do
      [{id, data}] ->
        merged_status = Map.merge(Map.get(data, :status, %{}), normalize_status(status))

        new_data =
          data |> Map.put(:status, merged_status) |> Map.put(:online, status_online?(status))

        :ets.insert(@table, {id, new_data})

      _ ->
        :ets.insert(
          @table,
          {device_id,
           %{
             id: device_id,
             type: infer_type(device_id),
             metrics: %{},
             status: normalize_status(status),
             last_seen: System.system_time(:millisecond),
             online: status_online?(status)
           }}
        )
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_cast({:update_status, device_id, status_updates}, state)
      when is_map(status_updates) do
    case :ets.lookup(@table, device_id) do
      [{id, data}] ->
        current_status = Map.get(data, :status, %{})
        new_status = Map.merge(current_status, normalize_status(status_updates))
        new_data = data |> Map.put(:status, new_status)
        :ets.insert(@table, {id, new_data})

      _ ->
        # Seed plausible starting sensor values so the UI doesn't show scary 0s on first load.
        # Real values will arrive shortly via telemetry.
        initial_metrics = %{
          soil_moisture: 45.0 + :rand.uniform() * 15,
          temperature: 20.0 + :rand.uniform() * 6,
          humidity: 55.0 + :rand.uniform() * 15,
          battery: 85.0 + :rand.uniform() * 12
        }

        :ets.insert(
          @table,
          {device_id,
           %{
             id: device_id,
             type: infer_type(device_id),
             metrics: initial_metrics,
             status: normalize_status(status_updates),
             last_seen: System.system_time(:millisecond),
             online: true
           }}
        )
    end

    {:noreply, state}
  end

  defp normalize_status(status) when is_map(status) do
    # Safe merge for string/atom keys from JSON/status payloads.
    # Core fields (valve/auto) always present with safe defaults.
    # Rich config fields (thresholds, interval, water_to_target) are *only* included
    # when present in the payload. This prevents any partial update_device_status/2
    # or tiny status broadcast from clearing previously-known Auto Low/High etc.
    core = %{
      valve_open: get_bool(status, ["valve_open", "valveOpen", :valve_open], false),
      auto_mode: get_bool(status, ["auto_mode", "autoMode", :auto_mode], true)
    }

    core
    |> maybe_put(status, :moisture_low, ["moisture_low", "moistureLow"])
    |> maybe_put(status, :moisture_high, ["moisture_high", "moistureHigh"])
    |> maybe_put(status, :report_interval_closed_ms, [
      "report_interval_closed_ms",
      "reportIntervalClosedMs"
    ])
    |> maybe_put(status, :water_to_target, ["water_to_target", "waterToTarget"])
    |> maybe_put_last_command(status)
  end

  defp normalize_status(_), do: %{}

  # Only add the key to the accumulator if a non-nil value is present under any of the
  # accepted key variants. This makes normalize "sparse" for rich fields so that
  # partial updates (ticks, close_valve, birth) never overwrite good values with nil.
  defp maybe_put(acc, src, key, variants) do
    val =
      Enum.find_value([key | variants], fn k ->
        case Map.get(src, k) do
          nil -> nil
          v -> v
        end
      end)

    if val != nil, do: Map.put(acc, key, val), else: acc
  end

  defp maybe_put_last_command(acc, src) do
    val = Map.get(src, "last_command") || Map.get(src, :last_command)
    if val != nil, do: Map.put(acc, :last_command, val), else: acc
  end

  defp get_bool(map, keys, default) do
    Enum.find_value(keys, default, fn k ->
      case Map.get(map, k) do
        v when is_boolean(v) -> v
        v when is_binary(v) -> v in ["true", "1", "on"]
        _ -> nil
      end
    end)
  end

  defp status_online?(status) do
    case status do
      %{"state" => "online"} -> true
      %{state: "online"} -> true
      %{"state" => "offline"} -> false
      %{state: "offline"} -> false
      _ -> true
    end
  end

  defp infer_type(id) do
    cond do
      String.contains?(id, "nerves") -> "nerves"
      String.contains?(id, "esp32") -> "esp32"
      true -> "sim"
    end
  end
end
