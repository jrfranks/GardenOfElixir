defmodule PlantMonitor.Plant do
  @moduledoc """
  On-device plant GenServer: physics tick, command handlers, MQTT publish.

  Command semantics match `FleetMonitor.Simulators.NervesPlant` so the
  console's Water Now / Auto / ping buttons work unchanged.
  """

  use GenServer
  require Logger
  alias PlantMonitor.{Mqtt, Physics}

  @tick_ms 200

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def apply_command(action, payload) when is_binary(action) and is_map(payload) do
    GenServer.cast(__MODULE__, {:command, action, payload})
  end

  def publish_now, do: GenServer.cast(__MODULE__, :publish_now)

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(opts) do
    device_id = Keyword.get(opts, :device_id) || Mqtt.device_id()
    transport = Keyword.get(opts, :transport, Mqtt)
    initial_moisture = 48.0 + :rand.uniform() * 8
    low = 18.0
    high = 52.0

    state = %{
      device_id: device_id,
      transport: transport,
      soil_moisture: initial_moisture,
      temperature: 21.0,
      humidity: 68.0,
      battery: 91.0,
      valve_open: Physics.initial_valve_state(initial_moisture, low, high),
      auto_mode: true,
      moisture_low: low,
      moisture_high: high,
      water_pulse_until: 0,
      water_to_target: false,
      last_telemetry_ms: 0,
      report_interval_closed_ms: 60_000,
      last_tick_ms: monotonic_ms()
    }

    Process.send_after(self(), :tick, @tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:command, action, payload}, state) do
    new_state = handle_command(action, payload, state)
    {:noreply, publish_all(new_state)}
  end

  def handle_cast(:publish_now, state) do
    {:noreply, publish_all(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    now = monotonic_ms()
    dt = max(0.01, (now - state.last_tick_ms) / 1000.0)
    sim_time = now
    new_state = tick_physics(%{state | last_tick_ms: now}, dt, now, sim_time)
    {:noreply, new_state}
  end

  def handle_info({:close_valve, _reason}, state) do
    {:noreply,
     publish_all(%{state | valve_open: false, water_pulse_until: 0, water_to_target: false})}
  end

  defp tick_physics(state, dt, now_real, sim_time) do
    seed = :erlang.phash2(state.device_id)
    temp = Physics.daily_temperature_cycle(now_real / 3_600_000.0, seed)
    moisture = Physics.update_moisture(state.soil_moisture, state.valve_open, temp, dt)
    water_boost = if state.valve_open, do: 8.0, else: 0.0
    humidity = Physics.humidity_for_temp(temp, water_boost)
    battery = Physics.update_battery(state.battery, state.valve_open, dt, seed)

    pulse_until = Map.get(state, :water_pulse_until, 0)
    pulse_active = pulse_until != 0 and pulse_until > now_real

    valve =
      cond do
        state.water_to_target ->
          moisture < state.moisture_high

        pulse_active ->
          true

        state.auto_mode ->
          Physics.auto_valve_state(
            state.valve_open,
            moisture,
            state.moisture_low,
            state.moisture_high
          )

        true ->
          state.valve_open
      end

    water_to_target =
      if state.water_to_target and not valve, do: false, else: state.water_to_target

    new_state = %{
      state
      | soil_moisture: moisture,
        temperature: temp,
        humidity: humidity,
        battery: Float.round(battery, 1),
        valve_open: valve,
        water_to_target: water_to_target
    }

    watering =
      valve or state.water_to_target or
        (pulse_until != 0 and pulse_until > now_real)

    desired = if watering, do: 15_000, else: state.report_interval_closed_ms

    if sim_time - state.last_telemetry_ms >= desired do
      publish_all(%{new_state | last_telemetry_ms: sim_time})
    else
      new_state
    end
  end

  defp handle_command("water_now", payload, state) do
    duration = get_duration(payload)

    if duration == 0 do
      %{state | valve_open: true, water_to_target: true, water_pulse_until: 0}
    else
      now = monotonic_ms()
      Process.send_after(self(), {:close_valve, :water_now_timeout}, duration)
      %{state | valve_open: true, water_pulse_until: now + duration, water_to_target: false}
    end
  end

  defp handle_command("set_auto_mode", payload, state) do
    enabled = get_bool(payload, "enabled", true)
    now = monotonic_ms()
    pulse_until = Map.get(state, :water_pulse_until, 0)
    pulse_active = pulse_until != 0 and pulse_until > now

    new_valve =
      if enabled and not pulse_active do
        Physics.initial_valve_state(state.soil_moisture, state.moisture_low, state.moisture_high)
      else
        state.valve_open
      end

    %{state | auto_mode: enabled, valve_open: new_valve}
  end

  defp handle_command("set_moisture_thresholds", payload, state) do
    min_gap = 3.0
    raw_low = Map.get(payload, "low", state.moisture_low)
    raw_high = Map.get(payload, "high", state.moisture_high)
    low = clamp_threshold(raw_low, 0, 99)
    high = clamp_threshold(raw_high, low + min_gap, 100)
    high = min(100.0, max(low + min_gap, high))
    low = max(0.0, min(high - min_gap, low))

    now = monotonic_ms()
    pulse_until = Map.get(state, :water_pulse_until, 0)
    pulse_active = pulse_until != 0 and pulse_until > now

    new_valve =
      if state.auto_mode and not pulse_active do
        Physics.initial_valve_state(state.soil_moisture, low, high)
      else
        state.valve_open
      end

    %{state | moisture_low: low, moisture_high: high, valve_open: new_valve}
  end

  defp handle_command("simulate_low_battery", _payload, state), do: %{state | battery: 7.0}

  defp handle_command("ping", _payload, state), do: state

  defp handle_command("stop_water", _payload, state) do
    %{state | valve_open: false, water_pulse_until: 0, water_to_target: false}
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

    %{state | report_interval_closed_ms: max(5_000, min(600_000, interval))}
  end

  defp handle_command("factory_reset", _payload, state) do
    initial_moisture = 48.0 + :rand.uniform() * 8
    low = 18.0
    high = 52.0

    %{
      state
      | soil_moisture: initial_moisture,
        temperature: 21.0,
        humidity: 68.0,
        battery: 91.0,
        valve_open: Physics.initial_valve_state(initial_moisture, low, high),
        auto_mode: true,
        moisture_low: low,
        moisture_high: high,
        water_pulse_until: 0,
        water_to_target: false,
        last_telemetry_ms: 0,
        report_interval_closed_ms: 60_000
    }
  end

  defp handle_command("reboot", _payload, state) do
    Logger.warning("reboot requested — stopping VM")

    spawn(fn ->
      Process.sleep(200)
      :init.stop()
    end)

    state
  end

  defp handle_command(_other, _p, state), do: state

  defp publish_all(state) do
    ts = System.system_time(:millisecond)

    metrics = %{
      soil_moisture: state.soil_moisture,
      temperature: state.temperature,
      humidity: state.humidity,
      battery: state.battery
    }

    pub = fn topic, payload, qos, retain ->
      state.transport.publish(topic, payload,
        client_id: state.device_id,
        qos: qos,
        retain: retain
      )
    end

    pub.("v1/dt/fleet/plant/#{state.device_id}/sensors", Jason.encode!(metrics), 0, false)

    Enum.each(metrics, fn {key, val} ->
      unit =
        case key do
          :soil_moisture -> "%"
          :temperature -> "C"
          :humidity -> "%"
          :battery -> "%"
        end

      pub.(
        "v1/dt/fleet/plant/#{state.device_id}/#{key}",
        Jason.encode!(%{value: val, unit: unit, ts: ts}),
        0,
        false
      )
    end)

    status = %{
      state: "online",
      type: "nerves",
      fw: PlantMonitor.version(),
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
    }

    pub.("v1/status/fleet/plant/#{state.device_id}", Jason.encode!(status), 1, true)
    %{state | last_telemetry_ms: monotonic_ms()}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

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
      %{"duration_ms" => 0} ->
        0

      %{"duration_ms" => d} when is_integer(d) and d > 0 ->
        min(d, 30_000)

      %{"duration_ms" => d} when is_binary(d) ->
        case Integer.parse(d) do
          {0, _} -> 0
          {i, _} when i > 0 -> min(i, 30_000)
          _ -> 5_000
        end

      _ ->
        5_000
    end
  end

  defp get_bool(payload, key, default) do
    case Map.get(payload, key) do
      v when is_boolean(v) -> v
      "true" -> true
      "false" -> false
      1 -> true
      0 -> false
      _ -> default
    end
  end
end
