defmodule PlantMonitor.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    device_id = Application.get_env(:plant_monitor, :device_id, "nerves-fw-001")

    children =
      if Application.get_env(:plant_monitor, :start_plant, true) do
        [{PlantMonitor.Plant, [device_id: device_id]}] ++
          mqtt_children(device_id) ++
          cluster_children()
      else
        []
      end

    opts = [strategy: :one_for_one, name: PlantMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp mqtt_children(device_id) do
    if Application.get_env(:plant_monitor, :start_mqtt, true) do
      host = Application.get_env(:plant_monitor, :mqtt_host, "127.0.0.1")
      port = Application.get_env(:plant_monitor, :mqtt_port, 1883)
      status_topic = "v1/status/fleet/plant/#{device_id}"
      cmd_filter = "v1/cmd/fleet/plant/#{device_id}/#"

      will = %Tortoise311.Package.Publish{
        topic: status_topic,
        payload: Jason.encode!(%{state: "offline", reason: "disconnected", type: "nerves"}),
        qos: 1,
        retain: true
      }

      Logger.info("mqtt client starting", device: device_id, host: host, port: port)

      [
        {Tortoise311.Connection,
         [
           client_id: device_id,
           handler: {PlantMonitor.MqttHandler, [device_id: device_id]},
           server: {Tortoise311.Transport.Tcp, host: String.to_charlist(host), port: port},
           subscriptions: [{cmd_filter, 1}],
           will: will,
           keep_alive: 30,
           clean_session: false
         ]}
      ]
    else
      []
    end
  end

  defp cluster_children do
    if Application.get_env(:plant_monitor, :cluster_enabled, false) do
      topologies = [
        gossip: [
          strategy: Cluster.Strategy.Gossip,
          config: [port: 45892, if_addr: "0.0.0.0", multicast_addr: "230.1.1.251"]
        ]
      ]

      [{Cluster.Supervisor, [topologies, [name: PlantMonitor.ClusterSupervisor]]}]
    else
      []
    end
  end
end
