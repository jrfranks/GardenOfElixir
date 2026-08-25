defmodule PlantMonitor.MqttHandler do
  @moduledoc false
  use Tortoise311.Handler
  require Logger

  def init(args) do
    {:ok, %{device_id: Keyword.fetch!(args, :device_id)}}
  end

  def connection(:up, state) do
    Logger.info("mqtt connected", device: state.device_id)
    PlantMonitor.Plant.publish_now()
    {:ok, state}
  end

  def connection(:down, state) do
    Logger.warning("mqtt disconnected", device: state.device_id)
    {:ok, state}
  end

  def handle_message(
        ["v1", "cmd", "fleet", "plant", id, action],
        payload,
        %{device_id: id} = state
      ) do
    map =
      case Jason.decode(payload) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    Logger.info("command", device: id, action: action)
    PlantMonitor.Plant.apply_command(action, map)
    {:ok, state}
  end

  def handle_message(_topic, _payload, state), do: {:ok, state}

  def subscription(_status, _topic, state), do: {:ok, state}

  def terminate(_reason, _state), do: :ok
end
