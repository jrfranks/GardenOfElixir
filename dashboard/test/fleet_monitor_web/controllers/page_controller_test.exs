defmodule FleetMonitorWeb.PageControllerTest do
  use FleetMonitorWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    # The root now serves the custom Phase 3 Fleet Console LiveView
    assert html_response(conn, 200) =~ "Fleet Console"
    assert html_response(conn, 200) =~ "Phase 3"
  end
end
