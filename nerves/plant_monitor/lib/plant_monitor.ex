defmodule PlantMonitor do
  @moduledoc """
  Nerves plant-monitor firmware.

  Host (`MIX_TARGET=host`, default): Elixir MQTT node using tortoise311 — same
  topic schema as the Fleet Console simulators and the ESP-IDF firmware.

  Device (`MIX_TARGET=x86_64`): real Nerves firmware image (`mix firmware`)
  with nerves_pack (ssh, mdns, vintage_net) plus optional libcluster gossip.
  """

  def version do
    Application.spec(:plant_monitor, :vsn) |> to_string()
  end
end
