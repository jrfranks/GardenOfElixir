defmodule PlantMonitor.CaptureTransport do
  @moduledoc false

  def publish(topic, payload, opts) do
    case Process.whereis(:plant_test_sink) do
      nil -> :ok
      pid -> send(pid, {:mqtt, topic, payload, opts})
    end

    :ok
  end
end
