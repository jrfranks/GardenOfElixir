defmodule FleetMonitor.PlantPhysics do
  @moduledoc """
  Pure functional plant sensor physics model for realistic IoT simulation.

  Used by both NervesPlant and Esp32Plant simulators.

  Goals:
  - Looks like real greenhouse sensors (not perfect sine waves)
  - Deterministic per device (great for demos, debugging, and tests)
  - Natural-looking noise, drift, and secondary effects (e.g. watering → humidity bump)
  - Different "personality" between device types (Nerves = cleaner, ESP32 = noisier)

  The data you see in the Fleet Console is generated here.
  """

  @type moisture :: float()
  @type temp_c :: float()
  @type humidity :: float()
  @type battery :: float()

  # ------------------------------------------------------------------
  # Public API (kept stable for the simulators)
  # ------------------------------------------------------------------

  @doc """
  Updates soil moisture at fixed demo rates (tuned for visible but not instant movement):

  - Valve open (watering): +0.1% per second
  - Valve closed: -0.02% per second

  Rates are applied proportionally to the actual elapsed `dt_seconds` (from the
  centralized SimulationTimer) so the behavior is smooth and deterministic
  regardless of tick jitter.
  """
  @spec update_moisture(moisture, boolean(), temp_c, number()) :: moisture
  def update_moisture(current, valve_open?, _temp_c, dt_seconds) when is_number(dt_seconds) do
    if valve_open? do
      # +0.1% per second when the valve is open (visible, gradual watering)
      rate_per_sec = 0.1
      new = current + rate_per_sec * dt_seconds
      min(100.0, new)
    else
      # -0.02% per second when idle (slow, realistic drying)
      rate_per_sec = 0.02
      new = current - rate_per_sec * dt_seconds
      max(0.0, new)
    end
  end

  @doc """
  Daily temperature cycle + realistic micro-variations.

  - Smooth diurnal sine
  - Slow random-walk drift (simulates weather fronts, shade, etc.)
  - Small high-frequency sensor noise

  The `device_seed` makes each plant have its own slightly different micro-climate.
  """
  @spec daily_temperature_cycle(number(), term()) :: temp_c
  def daily_temperature_cycle(hour_float, device_seed) do
    h = :math.fmod(hour_float, 24.0)
    # Peak slightly after solar noon
    rad = (h - 14.5) * 2 * :math.pi() / 24

    # Main daily swing
    daily = 19.5 + 10.8 * :math.sin(rad)

    # Slow drift (changes over ~hours). Reproducible per device.
    drift = seeded_noise(device_seed, trunc(hour_float * 4), 1.8)

    # Fast sensor noise (looks like real ADC jitter)
    fast_noise = seeded_noise(device_seed, trunc(hour_float * 120), 0.35)

    (daily + drift + fast_noise)
    |> Float.round(1)
  end

  @doc """
  Humidity that feels alive:
  - Strong inverse relationship with temperature (classic greenhouse behavior)
  - Temporary bump when recently watered (evaporation)
  - Its own slow natural variation
  """
  @spec humidity_for_temp(temp_c, number()) :: humidity
  def humidity_for_temp(temp_c, water_boost \\ 0.0) do
    base = 68.0 - (temp_c - 16.0) * 1.65

    # Watering adds a decaying humidity spike (very realistic)
    boosted = base + water_boost

    # Small organic variation
    variation = :math.sin(temp_c * 0.7) * 2.2

    boosted
    |> Kernel.+(variation)
    |> max(28.0)
    |> min(94.0)
    |> Float.round(1)
  end

  @doc """
  Battery model with slight realism:
  - Baseline quiescent drain
  - Extra cost when the valve/pump is active
  - Tiny stochastic-looking drain variation (still deterministic per device)
  """
  @spec update_battery(battery, boolean(), number(), term()) :: battery
  def update_battery(current, valve_open?, dt_seconds, device_seed \\ nil) do
    base = 0.00078 * dt_seconds
    pump = if valve_open?, do: 0.0058 * dt_seconds, else: 0.0

    # Very small "real world" variation
    jitter =
      if device_seed do
        seeded_noise(device_seed, System.os_time(:second), 0.00015) * dt_seconds
      else
        0.0
      end

    max(0.0, current - base - pump - jitter)
    |> Float.round(1)
  end

  @doc """
  Hysteresis auto-irrigation logic used on every simulation tick while Auto mode is active.

  Preserves the previous valve state while moisture is between low and high.
  This prevents rapid on/off chatter near the thresholds.
  """
  @spec auto_valve_state(boolean(), moisture, moisture, moisture) :: boolean()
  def auto_valve_state(current_valve, moisture, low, high) do
    cond do
      moisture <= low -> true
      moisture >= high -> false
      true -> current_valve
    end
  end

  @doc """
  Strict initialization / configuration rule for the valve.

  Used when a node first starts or receives new Auto Low / Auto High thresholds
  from the console. The node "initializes" its valve decision based on the
  current moisture and the freshly configured thresholds:

    - moisture <= Auto Low  → valve open   (must water)
    - moisture >= Auto High → valve closed (no need to water)
    - otherwise (in band)   → valve closed (safe default)

  This guarantees that after configuration the valve is never left open when
  moisture has already reached or exceeded the new Auto High.
  """
  @spec initial_valve_state(moisture, moisture, moisture) :: boolean()
  def initial_valve_state(moisture, low, high) do
    cond do
      moisture <= low -> true
      moisture >= high -> false
      true -> false
    end
  end

  @doc "Convenience snapshot used by some tests."
  @spec sample_sensors(map()) :: map()
  def sample_sensors(state) do
    %{
      soil_moisture: Map.get(state, :soil_moisture, 45.0),
      temperature: Map.get(state, :temperature, 22.0),
      humidity: Map.get(state, :humidity, 65.0),
      battery: Map.get(state, :battery, 87.0)
    }
  end

  # ------------------------------------------------------------------
  # Internal helpers
  # ------------------------------------------------------------------

  # Produces smooth, deterministic "noise" that looks natural.
  # Different devices get different but repeatable patterns.
  defp seeded_noise(seed, tick, amplitude) do
    # Combine device identity + time for a nice varying but stable signal
    x = :erlang.phash2({seed, tick}, 1_000_000) / 500_000.0 - 1.0
    # Two sine waves at different frequencies give a more organic shape
    (:math.sin(x * 5.3) * 0.6 + :math.sin(x * 11.7 + tick * 0.09) * 0.4) * amplitude
  end
end
