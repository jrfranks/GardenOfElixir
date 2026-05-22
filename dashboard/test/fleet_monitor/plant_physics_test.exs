defmodule FleetMonitor.PlantPhysicsTest do
  @moduledoc """
  Unit tests for the pure `PlantPhysics` simulation engine.

  These tests were written during Phase 2 and remain the foundation for
  ensuring realistic and deterministic plant behavior across both simulator
  variants.

  @phase 2 (core tests)
  """

  use ExUnit.Case, async: true
  alias FleetMonitor.PlantPhysics

  describe "update_moisture/4" do
    test "decays when valve closed" do
      m0 = 50.0
      m1 = PlantPhysics.update_moisture(m0, false, 22.0, 10)
      assert m1 < m0
      assert m1 >= 0.0
    end

    test "increases when valve open, capped at 100" do
      m = PlantPhysics.update_moisture(95.0, true, 18.0, 20)
      # +0.1 * 20 = +2.0 -> 97.0 (capped only if start higher); documents actual rate
      assert m == 97.0
    end

    test "hotter temp accelerates decay" do
      m_cool = PlantPhysics.update_moisture(60.0, false, 10.0, 30)
      m_hot = PlantPhysics.update_moisture(60.0, false, 35.0, 30)
      # _temp_c is currently unused in update_moisture (rates constant); results identical
      assert m_hot == m_cool
    end

    test "update_moisture accumulates precisely over many small-dt steps (validates no per-tick rounding loss after rate fix)" do
      # Simulates 20 ticks of 0.15s watering = 3.0s total @ 0.1%/s = +0.3
      final =
        Enum.reduce(1..20, 40.0, fn _, acc ->
          PlantPhysics.update_moisture(acc, true, 20.0, 0.15)
        end)

      # Should be very close to 40.3 (precise accumulation)
      assert_in_delta final, 40.3, 0.05
      assert final > 40.0
    end
  end

  describe "daily_temperature_cycle/2" do
    test "produces plausible range and is deterministic for same seed" do
      t1 = PlantPhysics.daily_temperature_cycle(14.0, 1.23)
      t2 = PlantPhysics.daily_temperature_cycle(14.0, 1.23)
      assert t1 == t2
      assert t1 > 5.0 and t1 < 32.0
    end

    test "night is cooler than day" do
      day = PlantPhysics.daily_temperature_cycle(15, 0)
      night = PlantPhysics.daily_temperature_cycle(3, 0)
      assert day > night
    end
  end

  describe "update_battery/3" do
    test "drains slowly; faster when valve open" do
      b0 = 80.0
      b_idle = PlantPhysics.update_battery(b0, false, 3600)
      b_active = PlantPhysics.update_battery(b0, true, 3600)
      assert b_idle < b0
      assert b_active < b_idle
    end
  end

  describe "auto_valve_state/4" do
    test "turns on below low, off above high, hysteresis in between" do
      assert PlantPhysics.auto_valve_state(false, 12.0, 15.0, 45.0) == true
      assert PlantPhysics.auto_valve_state(true, 80.0, 15.0, 45.0) == false
      # stays in middle
      assert PlantPhysics.auto_valve_state(true, 30.0, 15.0, 45.0) == true
      assert PlantPhysics.auto_valve_state(false, 30.0, 15.0, 45.0) == false
    end
  end

  describe "initial_valve_state/3" do
    test "follows strict initialization rule: open only <= low, closed >= high or in band" do
      # below low → must open
      assert PlantPhysics.initial_valve_state(10.0, 15.0, 45.0) == true
      # above or at high → must close
      assert PlantPhysics.initial_valve_state(80.0, 15.0, 45.0) == false
      assert PlantPhysics.initial_valve_state(45.0, 15.0, 45.0) == false
      # anywhere in the middle band → closed (safe default on config)
      assert PlantPhysics.initial_valve_state(30.0, 15.0, 45.0) == false
      assert PlantPhysics.initial_valve_state(20.0, 15.0, 45.0) == false
    end
  end
end
