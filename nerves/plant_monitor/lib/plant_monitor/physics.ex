defmodule PlantMonitor.Physics do
  @moduledoc """
  Copy of `FleetMonitor.PlantPhysics` (dashboard) kept next to the firmware
  so a Nerves node does not depend on the Phoenix app. Keep the rates in
  sync: moisture +0.1%/s open, −0.02%/s closed; same hysteresis helpers.
  """

  def update_moisture(current, valve_open?, _temp_c, dt_seconds) when is_number(dt_seconds) do
    if valve_open? do
      min(100.0, current + 0.1 * dt_seconds)
    else
      max(0.0, current - 0.02 * dt_seconds)
    end
  end

  def daily_temperature_cycle(hour_float, device_seed) do
    h = :math.fmod(hour_float, 24.0)
    rad = (h - 14.5) * 2 * :math.pi() / 24
    daily = 19.5 + 10.8 * :math.sin(rad)
    drift = seeded_noise(device_seed, trunc(hour_float * 4), 1.8)
    fast_noise = seeded_noise(device_seed, trunc(hour_float * 120), 0.35)

    (daily + drift + fast_noise)
    |> Float.round(1)
  end

  def humidity_for_temp(temp_c, water_boost \\ 0.0) do
    base = 68.0 - (temp_c - 16.0) * 1.65

    (base + water_boost + :math.sin(temp_c * 0.7) * 2.2)
    |> max(28.0)
    |> min(94.0)
    |> Float.round(1)
  end

  def update_battery(current, valve_open?, dt_seconds, device_seed \\ nil) do
    base = 0.00078 * dt_seconds
    pump = if valve_open?, do: 0.0058 * dt_seconds, else: 0.0

    jitter =
      if device_seed do
        seeded_noise(device_seed, System.os_time(:second), 0.00015) * dt_seconds
      else
        0.0
      end

    max(0.0, current - base - pump - jitter)
    |> Float.round(1)
  end

  def auto_valve_state(current_valve, moisture, low, high) do
    cond do
      moisture <= low -> true
      moisture >= high -> false
      true -> current_valve
    end
  end

  def initial_valve_state(moisture, low, high) do
    cond do
      moisture <= low -> true
      moisture >= high -> false
      true -> false
    end
  end

  defp seeded_noise(seed, tick, amplitude) do
    x = :erlang.phash2({seed, tick}, 1_000_000) / 500_000.0 - 1.0
    (:math.sin(x * 5.3) * 0.6 + :math.sin(x * 11.7 + tick * 0.09) * 0.4) * amplitude
  end
end
