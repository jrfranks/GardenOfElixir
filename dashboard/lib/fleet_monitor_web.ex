defmodule FleetMonitorWeb do
  @moduledoc """
  The web interface layer for the Fleet Console.

  This module defines the macros used throughout the web layer
  (`use FleetMonitorWeb, :live_view`, `:component`, `:html`, etc.).

  Key customizations in this project:
  - The main console (`FleetConsoleLive`) uses a custom full-bleed
    industrial dark theme instead of the default `Layouts.app`.
  - Heavy use of `Phoenix.LiveView.stream/3` for the event log.
  - Custom components (`DeviceCard`) for rich per-device visualization.

  See `DESIGN.md` and `router.ex` for layout and routing decisions.

  This file is mostly standard Phoenix 1.8 boilerplate with minor
  customizations for the demo console.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import FleetMonitorWeb.CoreComponents

      # Common modules used in templates
      alias FleetMonitorWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: FleetMonitorWeb.Endpoint,
        router: FleetMonitorWeb.Router,
        statics: FleetMonitorWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
