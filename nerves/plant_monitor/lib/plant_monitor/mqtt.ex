defmodule PlantMonitor.Mqtt do
  @moduledoc """
  Thin publisher used by `Plant`. Swallows errors so a missing broker never
  kills the plant process (same fire-and-forget idea as the dashboard sims).
  """

  require Logger

  def publish(topic, payload, opts \\ []) when is_binary(topic) and is_binary(payload) do
    client_id = Keyword.get(opts, :client_id) || device_id()
    qos = Keyword.get(opts, :qos, 0)
    retain = Keyword.get(opts, :retain, false)

    try do
      case Tortoise311.publish(client_id, topic, payload, qos: qos, retain: retain) do
        :ok ->
          :ok

        {:ok, _ref} ->
          :ok

        {:error, reason} ->
          Logger.debug("mqtt publish failed", reason: inspect(reason), topic: topic)
          {:error, reason}
      end
    catch
      kind, reason ->
        Logger.debug("mqtt publish crashed", kind: kind, reason: inspect(reason))
        :ok
    end
  end

  def device_id do
    Application.get_env(:plant_monitor, :device_id, "nerves-fw-001")
  end
end
