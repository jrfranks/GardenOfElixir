defmodule FleetMonitor.Simulators.NervesPlant do
  @moduledoc """
  "Nerves-style" plant monitoring simulator (Elixir GenServer).

  This is one of the two concrete implementations of the `DeviceSimulator`
  behaviour. It represents a well-behaved Elixir/Nerves device that:
  - Runs realistic physics via `PlantPhysics`
  - Reacts to commands received over the hybrid path (MQTT + internal PubSub)
  - Publishes both per-metric and aggregate telemetry through `MqttBridge`

  "Nerves flavour" characteristics (to make the demo feel heterogeneous):
  - Uses the centralized `SimulationTimer` for coordinated ticks
  - Lower sensor noise (more "precise" native feel)
  - Same physics engine as the ESP32 variant for consistency

  Command handling (Phase 3) was added so that "Water Now", Auto Mode,
  Low Battery simulation, etc. actually affect the running physics and are
  visible in the UI and on the MQTT wire.

  See `DESIGN.md` and the sibling `esp32_plant.ex` for the design rationale.

  @phase 2 (base) + Phase 3 (command handling + status feedback)
  """

  use GenServer
  alias FleetMonitor.PlantPhysics
  require Logger

  @behaviour FleetMonitor.Simulators.DeviceSimulator

  @impl FleetMonitor.Simulators.DeviceSimulator
  def start_link(opts) do
    device_id = Keyword.fetch!(opts, :device_id)
    GenServer.start_link(__MODULE__, opts, name: via(device_id))
  end

  defp via(id), do: {:via, Registry, {FleetMonitor.DeviceRegistry, id}}

  # Behaviour callbacks
  @impl FleetMonitor.Simulators.DeviceSimulator
  def device_id(pid), do: GenServer.call(pid, :device_id)
  @impl FleetMonitor.Simulators.DeviceSimulator
  def device_type, do: :nerves

  @impl true
  def init(opts) do
    device_id = Keyword.fetch!(opts, :device_id)

    initial_moisture = 48.0 + :rand.uniform() * 8

    # The node initializes the valve open/close status based on the current
    # moisture level using the strict configuration rule:
    #   moisture <= Auto Low  → open
    #   moisture >= Auto High → closed
    #   otherwise             → closed
    initial_valve = PlantPhysics.initial_valve_state(initial_moisture, 18.0, 52.0)

    state = %{
      device_id: device_id,
      type: :nerves,
      soil_moisture: initial_moisture,
      temperature: 21.0,
      humidity: 68.0,
      battery: 91.0,
      valve_open: initial_valve,
      auto_mode: true,
      moisture_low: 18.0,
      moisture_high: 52.0,
      water_pulse_until: 0,
      water_to_target: false,
      last_telemetry_ms: 0,
      # adjustable when not actively watering
      report_interval_closed_ms: 60_000
    }

    Logger.info("NervesPlant starting", device: device_id)

    # Publish initial retained status containing the node's full current state
    # (sensors + control/config values) so that status topics always reflect
    # everything the node knows about itself.
    publish_status(state)

    # Subscribe to the central simulation timer (replaces per-device send_after)
    Phoenix.PubSub.subscribe(FleetMonitor.PubSub, "simulation:tick")

    # Phase 3: subscribe for command delivery
    # (PubSub fanout from MqttBridge; works for local sims + future clustered)
    Phoenix.PubSub.subscribe(FleetMonitor.PubSub, "fleet:commands")

    {:ok, state}
  end

  @impl true
  def handle_call(:device_id, _from, state), do: {:reply, state.device_id, state}

  # Receives coordinated ticks from the central SimulationTimer.
  # All devices get the same simulated dt, making physics behavior
  # predictable and controllable via simulation speed.
  @impl true
  def handle_info({:simulation_tick, dt_seconds, sim_time}, state) do
    # Use the dt provided by the simulation timer (already scaled by speed)
    dt = max(0.01, dt_seconds)

    # Physics updates (pure, seeded per device for reproducible but natural variation)
    seed = :erlang.phash2(state.device_id)
    # We still use real monotonic time for the daily temperature cycle
    # (the "sun" moves on wall time), but moisture/valve use simulated dt.
    now_real = System.monotonic_time(:millisecond)
    temp = PlantPhysics.daily_temperature_cycle(now_real / 3_600_000.0, seed)

    moisture = PlantPhysics.update_moisture(state.soil_moisture, state.valve_open, temp, dt)

    # Watering creates a visible temporary humidity spike (very realistic greenhouse behavior)
    water_boost = if state.valve_open, do: 8.0, else: 0.0
    humidity = PlantPhysics.humidity_for_temp(temp, water_boost)

    battery = PlantPhysics.update_battery(state.battery, state.valve_open, dt, seed)

    # Phase 3: respect auto_mode + hysteresis, but a recent manual "Water Now" takes priority
    # for the commanded duration (so moisture actually rises as expected).
    # (now_real fetched once per tick for consistent timestamp across physics + valve decision)

    valve =
      cond do
        # "Water Now" (to target) has highest priority: keep watering until we hit Auto High.
        state.water_to_target ->
          if moisture >= state.moisture_high do
            false
          else
            true
          end

        # Manual water pulse is still active.
        # We use != 0 (cleared sentinel) + comparative check so it works even when
        # System.monotonic_time(:millisecond) returns large negative values.
        (pulse_until = Map.get(state, :water_pulse_until, 0)) != 0 and pulse_until > now_real ->
          true

        state.auto_mode ->
          PlantPhysics.auto_valve_state(
            state.valve_open,
            moisture,
            state.moisture_low,
            state.moisture_high
          )

        true ->
          state.valve_open
      end

    # Clear water_to_target flag once we have reached the target and closed the valve.
    water_to_target =
      if state.water_to_target and not valve do
        false
      else
        state.water_to_target
      end

    new_state = %{
      state
      | soil_moisture: moisture,
        temperature: temp,
        humidity: humidity,
        battery: Float.round(battery, 1),
        valve_open: valve,
        water_to_target: water_to_target
    }

    # Update authoritative store for the console (used by telemetry reconciliation)
    # Pass the full set of control fields so partial ticks never drop thresholds / interval / water_to_target.
    FleetMonitor.FleetState.update_device_status(
      new_state.device_id,
      Map.take(new_state, [
        :valve_open,
        :auto_mode,
        :moisture_low,
        :moisture_high,
        :report_interval_closed_ms,
        :water_to_target
      ])
    )

    # When auto logic changes the valve (moisture crossed Auto High or Low),
    # also broadcast on the status topic so the LiveView updates the valve badge
    # immediately and consistently with the moisture sample.
    if valve != state.valve_open do
      Phoenix.PubSub.broadcast(
        FleetMonitor.PubSub,
        "fleet:status",
        {:status, new_state.device_id,
         Map.take(new_state, [
           :valve_open,
           :auto_mode,
           :moisture_low,
           :moisture_high,
           :report_interval_closed_ms,
           :water_to_target
         ])}
      )
    end

    # Dynamic telemetry reporting frequency:
    # - 4 updates per minute (every 15s simulated) when actively watering (valve open due to Water Now / pulse)
    # - 1 update per `report_interval_closed_ms` (adjustable, default 60s) when valve is closed / in normal auto mode.
    is_watering_active =
      valve or state.water_to_target or
        (Map.get(state, :water_pulse_until, 0) != 0 and
           Map.get(state, :water_pulse_until, 0) > now_real)

    desired_interval =
      if is_watering_active do
        # 4 times per minute when watering
        15_000
      else
        state.report_interval_closed_ms
      end

    final_new_state =
      if sim_time - state.last_telemetry_ms >= desired_interval do
        metrics = %{
          soil_moisture: new_state.soil_moisture,
          temperature: new_state.temperature,
          humidity: new_state.humidity,
          battery: new_state.battery
        }

        safe_publish_telemetry(new_state.device_id, metrics)
        publish_status(new_state)

        %{new_state | last_telemetry_ms: sim_time}
      else
        new_state
      end

    {:noreply, final_new_state}
  end

  # Phase 3 command handling (receives from MqttBridge PubSub broadcast on cmd publish)
  # Same path works for MQTT-only devices in future.
  # Note: "ping" participates here only to trigger the immediate publish_current_telemetry
  # used by the LV probe for authoritative end-to-end timing (handle_command("ping") is a pure no-op).
  @impl true
  def handle_info({:command_sent, dev_id, action, payload}, %{device_id: dev_id} = state) do
    new_state = handle_command(action, payload, state)
    publish_current_telemetry(new_state)

    safe_publish_status(new_state.device_id, %{
      state: "online",
      type: Atom.to_string(new_state.type),
      fw: "phase2-sim",
      last_seen: DateTime.utc_now() |> DateTime.to_iso8601(),
      valve_open: new_state.valve_open,
      auto_mode: new_state.auto_mode,
      moisture_low: new_state.moisture_low,
      moisture_high: new_state.moisture_high,
      soil_moisture: new_state.soil_moisture,
      temperature: new_state.temperature,
      humidity: new_state.humidity,
      battery: new_state.battery,
      report_interval_closed_ms: new_state.report_interval_closed_ms,
      water_to_target: new_state.water_to_target
    })

    FleetMonitor.FleetState.update_device_status(
      dev_id,
      Map.take(new_state, [
        :valve_open,
        :auto_mode,
        :moisture_low,
        :moisture_high,
        :report_interval_closed_ms,
        :water_to_target
      ])
    )

    {:noreply, new_state}
  end

  def handle_info({:command_sent, _other, _a, _p}, state), do: {:noreply, state}

  def handle_info({:close_valve, _reason}, state) do
    new_state = %{state | valve_open: false, water_pulse_until: 0, water_to_target: false}
    publish_current_telemetry(new_state)
    publish_status(new_state)

    FleetMonitor.FleetState.update_device_status(
      state.device_id,
      Map.take(new_state, [
        :valve_open,
        :auto_mode,
        :moisture_low,
        :moisture_high,
        :report_interval_closed_ms,
        :water_to_target
      ])
    )

    {:noreply, new_state}
  end

  defp handle_command("water_now", payload, state) do
    duration = get_duration(payload)

    if duration == 0 do
      # New "Water Now" behavior for the demo button:
      # Keep the valve open until moisture reaches the current Auto High level,
      # then automatically close.
      new_state = %{
        state
        | valve_open: true,
          water_to_target: true,
          water_pulse_until: 0
      }

      Logger.info("NervesPlant: water_now (to target) received", device: state.device_id)
      new_state
    else
      # Traditional timed pulse (used by tests and legacy calls)
      now = System.monotonic_time(:millisecond)

      new_state = %{
        state
        | valve_open: true,
          water_pulse_until: now + duration,
          water_to_target: false
      }

      Process.send_after(self(), {:close_valve, :water_now_timeout}, duration)

      Logger.info("NervesPlant: water_now received",
        device: state.device_id,
        duration_ms: duration
      )

      new_state
    end
  end

  defp handle_command("set_auto_mode", payload, state) do
    enabled = get_bool(payload, "enabled", true)

    # When re-enabling auto, the node re-initializes its valve using the strict
    # configuration rule based on current moisture vs its (latest) thresholds.
    now = System.monotonic_time(:millisecond)
    pulse_until = Map.get(state, :water_pulse_until, 0)
    pulse_active = pulse_until != 0 and pulse_until > now

    new_valve =
      if enabled and not pulse_active do
        PlantPhysics.initial_valve_state(
          state.soil_moisture,
          state.moisture_low,
          state.moisture_high
        )
      else
        state.valve_open
      end

    new_state = %{state | auto_mode: enabled, valve_open: new_valve}

    Logger.info("NervesPlant: set_auto_mode", device: state.device_id, enabled: enabled)
    new_state
  end

  defp handle_command("set_moisture_thresholds", payload, state) do
    min_gap = 3.0

    raw_low = Map.get(payload, "low", state.moisture_low)
    raw_high = Map.get(payload, "high", state.moisture_high)

    low = clamp_threshold(raw_low, 0, 99)
    high = clamp_threshold(raw_high, low + min_gap, 100)

    # Final defensive normalization (node-side safety for untrusted payloads / direct MQTT):
    # guarantees high <= 100, low >= 0, and min_gap even for extreme/malformed input.
    high = min(100.0, max(low + min_gap, high))
    low = max(0.0, min(high - min_gap, low))

    # When the node receives new Auto Low / Auto High values it re-initializes
    # its valve decision using the strict configuration rule (never leave the
    # valve open if moisture has already reached or exceeded the new High).
    now = System.monotonic_time(:millisecond)
    pulse_until = Map.get(state, :water_pulse_until, 0)
    pulse_active = pulse_until != 0 and pulse_until > now

    new_valve =
      if state.auto_mode and not pulse_active do
        PlantPhysics.initial_valve_state(state.soil_moisture, low, high)
      else
        state.valve_open
      end

    new_state = %{state | moisture_low: low, moisture_high: high, valve_open: new_valve}

    Logger.info("NervesPlant: set_moisture_thresholds",
      device: state.device_id,
      low: low,
      high: high
    )

    # Publish full node status (retained) with latest sensors + config.
    publish_status(new_state)

    new_state
  end

  defp handle_command("simulate_low_battery", _payload, state) do
    new_state = %{state | battery: 7.0}

    FleetMonitor.FleetState.update_device_status(state.device_id, %{
      last_command: "simulate_low_battery"
    })

    Logger.info("NervesPlant: simulate_low_battery", device: state.device_id)
    new_state
  end

  defp handle_command("ping", _payload, state) do
    # Side-effect-free ping for the improved roundtrip latency probe (educational hybrid demo).
    # Does nothing to valve/auto/battery/physics. The caller (handle_info for :command_sent)
    # always does publish_current_telemetry(new_state) afterward, giving us the
    # authoritative telemetry confirmation used for end-to-end timing.
    # Empty payload is safe (no parsing). Explicit clause for clarity.
    Logger.info("NervesPlant: ping received (latency probe, no side effects)",
      device: state.device_id
    )

    state
  end

  defp handle_command("stop_water", _payload, state) do
    new_state = %{state | valve_open: false, water_pulse_until: 0, water_to_target: false}

    Logger.info("NervesPlant: stop_water received", device: state.device_id)
    new_state
  end

  defp handle_command("set_telemetry_interval", payload, state) do
    raw = Map.get(payload, "interval_ms", 60_000)

    interval =
      case raw do
        v when is_integer(v) ->
          v

        v when is_binary(v) ->
          case Integer.parse(v) do
            {i, _} -> i
            _ -> 60_000
          end

        _ ->
          60_000
      end

    # Reasonable bounds: 5 seconds to 10 minutes
    interval = max(5_000, min(600_000, interval))

    new_state = %{state | report_interval_closed_ms: interval}

    Logger.info("NervesPlant: telemetry interval (closed) set",
      device: state.device_id,
      interval_ms: interval
    )

    new_state
  end

  defp handle_command(_other, _p, state), do: state

  defp clamp_threshold(val, min_val, max_val) do
    num =
      case val do
        v when is_binary(v) ->
          case Float.parse(v) do
            {f, _} -> f
            _ -> 0.0
          end

        v when is_number(v) ->
          v * 1.0

        _ ->
          0.0
      end

    max(min_val, min(max_val, num))
  end

  defp get_duration(payload) do
    case payload do
      %{"duration_ms" => d} when is_integer(d) and d > 0 ->
        min(d, 30_000)

      %{"duration_ms" => d} when is_binary(d) ->
        case Integer.parse(d) do
          {i, _} when i > 0 -> min(i, 30_000)
          _ -> 5_000
        end

      _ ->
        5_000
    end
  end

  defp get_bool(payload, key, default) do
    # String keys only (all command payloads from Commands facade + JSON use strings).
    # Removed atom fallback entirely to eliminate past-issue String.to_atom risk on any external data.
    case Map.get(payload, key) do
      v when is_boolean(v) -> v
      "true" -> true
      "false" -> false
      1 -> true
      0 -> false
      _ -> default
    end
  end

  defp publish_current_telemetry(state) do
    metrics = %{
      soil_moisture: state.soil_moisture,
      temperature: state.temperature,
      humidity: state.humidity,
      battery: state.battery
    }

    safe_publish_telemetry(state.device_id, metrics)
  end

  defp safe_publish_telemetry(device_id, metrics) do
    Task.start(fn ->
      try do
        FleetMonitor.MqttBridge.publish_telemetry(device_id, metrics)
      catch
        _, _ -> :ok
      end
    end)
  end

  defp safe_publish_status(device_id, status) do
    Task.start(fn ->
      try do
        FleetMonitor.MqttBridge.publish_status(device_id, status)
      catch
        _, _ -> :ok
      end
    end)
  end

  # Publishes a rich retained status message (fire-and-forget so a degraded
  # MqttBridge never kills the simulator — critical for test isolation and resilience).
  defp publish_status(state) do
    safe_publish_status(state.device_id, %{
      state: "online",
      type: Atom.to_string(state.type),
      fw: "phase2-sim",
      last_seen: DateTime.utc_now() |> DateTime.to_iso8601(),
      valve_open: state.valve_open,
      auto_mode: state.auto_mode,
      moisture_low: state.moisture_low,
      moisture_high: state.moisture_high,
      soil_moisture: state.soil_moisture,
      temperature: state.temperature,
      humidity: state.humidity,
      battery: state.battery,
      report_interval_closed_ms: state.report_interval_closed_ms,
      water_to_target: state.water_to_target
    })
  end
end
