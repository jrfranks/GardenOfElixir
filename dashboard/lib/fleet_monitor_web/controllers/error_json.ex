defmodule FleetMonitorWeb.ErrorJSON do
  @moduledoc """
  Renders error responses for JSON API requests.

  Currently unused in this application (there is no public JSON API yet),
  but kept for future expansion and completeness.

  See `config/config.exs` for error handling configuration.
  """

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  # def render("500.json", _assigns) do
  #   %{errors: %{detail: "Internal Server Error"}}
  # end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
