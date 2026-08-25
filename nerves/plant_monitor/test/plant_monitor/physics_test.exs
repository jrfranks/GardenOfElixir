defmodule PlantMonitor.PhysicsTest do
  use ExUnit.Case, async: true
  alias PlantMonitor.Physics

  test "moisture rates match the dashboard engine" do
    assert Physics.update_moisture(95.0, true, 18.0, 20) == 97.0
    assert Physics.update_moisture(50.0, false, 22.0, 10) == 49.8
  end

  test "hysteresis auto valve" do
    assert Physics.auto_valve_state(false, 12.0, 15.0, 45.0) == true
    assert Physics.auto_valve_state(true, 80.0, 15.0, 45.0) == false
    assert Physics.auto_valve_state(true, 30.0, 15.0, 45.0) == true
    assert Physics.auto_valve_state(false, 30.0, 15.0, 45.0) == false
  end

  test "temperature is deterministic per seed" do
    t1 = Physics.daily_temperature_cycle(14.0, 1.23)
    t2 = Physics.daily_temperature_cycle(14.0, 1.23)
    assert t1 == t2
    assert t1 > 5.0 and t1 < 32.0
  end
end
