defmodule FleetMonitorWeb.FleetConsoleLiveTest do
  use FleetMonitorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FleetMonitor.{DeviceManager, FleetState}

  setup do
    # Clear static demo devices so we can test empty-fleet UX deterministically.
    for id <- ["nerves-001", "esp32-042", "nerves-007"] do
      DeviceManager.stop_device(id)
      FleetState.remove_device(id)
    end

    on_exit(fn ->
      for {type, id} <- [{:nerves, "nerves-001"}, {:esp32, "esp32-042"}, {:nerves, "nerves-007"}] do
        if DeviceManager.lookup_pid(id) == nil do
          DeviceManager.start_device(type, id)
        end
      end
    end)

    :ok
  end

  test "water_all on empty fleet shows flash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> element("button", "💧 Water All") |> render_click()
    assert html =~ "No devices yet"
  end

  test "water_all with devices dispatches water_to_target commands", %{conn: conn} do
    {:ok, _pid1} = DeviceManager.start_device(:nerves, "test-lv-water-all-1")
    {:ok, _pid2} = DeviceManager.start_device(:esp32, "test-lv-water-all-2")

    Phoenix.PubSub.subscribe(FleetMonitor.PubSub, "fleet:commands")

    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> element("button", "💧 Water All") |> render_click()

    for id <- ["test-lv-water-all-1", "test-lv-water-all-2"] do
      assert_receive {:command_sent, ^id, "water_now", %{"duration_ms" => 0}}, 1000
    end

    DeviceManager.stop_device("test-lv-water-all-1")
    DeviceManager.stop_device("test-lv-water-all-2")
  end
end
