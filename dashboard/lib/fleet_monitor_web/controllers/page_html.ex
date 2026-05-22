defmodule FleetMonitorWeb.PageHTML do
  @moduledoc """
  HTML rendering module for the fallback `PageController`.

  Contains the default home template. Not used by the main
  `FleetConsoleLive` (which renders its own UI).
  """
  use FleetMonitorWeb, :html

  embed_templates "page_html/*"
end
