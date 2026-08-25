defmodule PlantMonitor.PlantTest do
  use ExUnit.Case, async: false
  alias PlantMonitor.Plant

  setup do
    Process.register(self(), :plant_test_sink)

    {:ok, _pid} =
      start_supervised(
        {Plant, [device_id: "nerves-test-1", transport: PlantMonitor.CaptureTransport]}
      )

    :ok
  end

  test "water_now with duration 0 opens valve to target" do
    Plant.apply_command("water_now", %{"duration_ms" => 0})
    snap = Plant.snapshot()
    assert snap.valve_open
    assert snap.water_to_target
  end

  test "stop_water closes the valve" do
    Plant.apply_command("water_now", %{"duration_ms" => 0})
    Plant.apply_command("stop_water", %{})
    snap = Plant.snapshot()
    refute snap.valve_open
    refute snap.water_to_target
  end

  test "set_moisture_thresholds clamps and stores" do
    Plant.apply_command("set_moisture_thresholds", %{"low" => 20, "high" => 60})
    snap = Plant.snapshot()
    assert snap.moisture_low == 20.0
    assert snap.moisture_high == 60.0
  end

  test "simulate_low_battery" do
    Plant.apply_command("simulate_low_battery", %{})
    assert Plant.snapshot().battery == 7.0
  end

  test "publish_now emits aggregate sensors + retained status" do
    Plant.publish_now()
    assert_receive {:mqtt, "v1/dt/fleet/plant/nerves-test-1/sensors", sensors, _}
    assert Jason.decode!(sensors)["soil_moisture"]
    assert_receive {:mqtt, "v1/status/fleet/plant/nerves-test-1", status, opts}
    decoded = Jason.decode!(status)
    assert decoded["type"] == "nerves"
    assert decoded["state"] == "online"
    assert opts[:retain] == true
    assert opts[:qos] == 1
  end

  test "ping is a no-op that still republishes" do
    before = Plant.snapshot()
    Plant.apply_command("ping", %{})
    after_snap = Plant.snapshot()
    assert after_snap.valve_open == before.valve_open
    assert_receive {:mqtt, "v1/dt/fleet/plant/nerves-test-1/sensors", _, _}
  end
end
