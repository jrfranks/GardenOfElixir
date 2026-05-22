defmodule FleetMonitor.SimulationTimer do
  @moduledoc """
  Centralized simulation timer for the Fleet Monitor demo.

  This replaces the previous decentralized per-device `Process.send_after`
  timers with a single source of simulated time.

  Features:
  - Configurable simulation speed (e.g. 1.0 = real time, 5.0 = 5x faster)
  - Broadcasts periodic `:simulation_tick` messages via PubSub
  - All devices (static + dynamically spawned) receive the same `dt` values
  - `dt` is based on simulated time, making physics deterministic and
    controllable regardless of real wall-clock jitter

  Devices subscribe to the topic "simulation:tick" and receive:

      {:simulation_tick, dt_seconds :: float(), simulated_time_ms :: integer()}

  The `dt_seconds` should be used directly in physics calculations
  (see `PlantPhysics.update_moisture/4` etc.).

  Speed can be changed at runtime via `set_speed/1`. A future UI control
  (speed slider in the Fleet Console) can drive this for live demo tuning.

  ## Example

      FleetMonitor.SimulationTimer.set_speed(3.0)   # 3x real time
      FleetMonitor.SimulationTimer.set_speed(0.5)   # half speed (slow motion)
  """

  use GenServer
  require Logger

  @pubsub_topic "simulation:tick"
  # How often we advance simulated time (smooth control)
  @real_tick_interval_ms 150

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Set the simulation speed multiplier.

  1.0 = real time
  > 1.0 = faster than real time (good for demos)
  < 1.0 = slower than real time (useful for debugging physics)
  0.0   = paused (dt will be 0)
  """
  def set_speed(speed) when is_number(speed) and speed >= 0 do
    GenServer.cast(__MODULE__, {:set_speed, speed * 1.0})
  end

  def get_speed do
    GenServer.call(__MODULE__, :get_speed)
  end

  @doc "Returns current simulated time in milliseconds since timer start."
  def get_simulated_time do
    GenServer.call(__MODULE__, :get_simulated_time)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Schedule the first real-world advance
    Process.send_after(self(), :advance, @real_tick_interval_ms)

    state = %{
      speed: 1.0,
      simulated_time_ms: 0,
      last_real_time: System.monotonic_time(:millisecond)
    }

    Logger.info("SimulationTimer started (real-time base, speed=1.0)")

    {:ok, state}
  end

  @impl true
  def handle_cast({:set_speed, new_speed}, state) do
    Logger.info("SimulationTimer speed changed: #{state.speed} → #{new_speed}")
    {:noreply, %{state | speed: new_speed}}
  end

  @impl true
  def handle_call(:get_speed, _from, state) do
    {:reply, state.speed, state}
  end

  @impl true
  def handle_call(:get_simulated_time, _from, state) do
    {:reply, state.simulated_time_ms, state}
  end

  @impl true
  def handle_info(:advance, state) do
    now = System.monotonic_time(:millisecond)
    real_dt_ms = max(0, now - state.last_real_time)

    # Scale by current simulation speed
    simulated_dt_ms = round(real_dt_ms * state.speed)
    simulated_dt_seconds = simulated_dt_ms / 1000.0

    new_sim_time = state.simulated_time_ms + simulated_dt_ms

    # Broadcast to all interested devices (Nerves, ESP32, future dynamic ones)
    Phoenix.PubSub.broadcast(
      FleetMonitor.PubSub,
      @pubsub_topic,
      {:simulation_tick, simulated_dt_seconds, new_sim_time}
    )

    # Schedule next advance
    Process.send_after(self(), :advance, @real_tick_interval_ms)

    {:noreply,
     %{
       state
       | simulated_time_ms: new_sim_time,
         last_real_time: now
     }}
  end
end
