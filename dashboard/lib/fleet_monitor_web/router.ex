defmodule FleetMonitorWeb.Router do
  @moduledoc """
  Phoenix Router for the Fleet Console.

  This router is intentionally minimal because the application is a single-purpose
  demo console:

  - All interactive functionality lives in `FleetConsoleLive` (mounted at `/`).
  - We only need the browser pipeline (session, CSRF protection, secure headers).
  - The API pipeline is defined for future expansion but not currently used.

  Important note on layout:
  The root layout (`FleetMonitorWeb.Layouts.root`) is set here for the browser
  pipeline. However, the main `FleetConsoleLive` deliberately renders its own
  full-bleed industrial dark theme and does **not** use the default `<Layouts.app>`
  wrapper (see the LiveView for rationale — it wants a wide control-room feel
  without the standard Phoenix app chrome).

  See `DESIGN.md` and the comments in `fleet_console_live.ex` for the layout decision.

  @phase 3 (customized from generated Phoenix 1.8 router)
  """

  use FleetMonitorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FleetMonitorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FleetMonitorWeb do
    pipe_through :browser

    # The entire "Wow" experience lives here.
    live "/", FleetConsoleLive, :index
  end

  # Other scopes may use custom stacks (kept for future API work).
  # scope "/api", FleetMonitorWeb do
  #   pipe_through :api
  # end
end
