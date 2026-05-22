defmodule FleetMonitorWeb.PageController do
  @moduledoc """
  Fallback page controller.

  In this application the root route (`/`) is handled by `FleetConsoleLive`
  (a LiveView). This controller and its template are remnants of the
  default Phoenix generator and are not used in the main Fleet Console flow.

  They are kept for completeness and to avoid breaking any generated
  static asset or error paths.
  """

  use FleetMonitorWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
