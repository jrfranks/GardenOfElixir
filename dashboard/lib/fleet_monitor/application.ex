defmodule FleetMonitor.Application do
  @moduledoc """
  OTP Application entry point for the Fleet Monitor console.

  This is where the entire supervision tree for the hybrid IoT demo is
  assembled. The tree contains:

  - Standard Phoenix pieces (Telemetry, DNSCluster, PubSub)
  - Core Phase 2 infrastructure:
      • DeviceRegistry (unique naming for all devices)
      • MqttBridge (the MQTT ↔ PubSub heart)
      • FleetState (authoritative in-memory fleet view)
  - Phase 3 dynamic lifecycle:
      • DeviceSupervisor (DynamicSupervisor for runtime devices)
  - Static demo devices (3 simulators started at boot for immediate `make demo` value)
  - The Phoenix endpoint

  Design notes:
  - We keep a small set of static devices for demo continuity while allowing
    fully dynamic add/remove via the UI (DeviceManager + DeviceSupervisor).
  - libcluster is configured but the actual Cluster.Supervisor child is
    intentionally left out in the current demo (see comments in the file).
  - All custom children follow the patterns established in Phase 2/3 reviews
    (safe child IDs, explicit Registry, one_for_one where appropriate).

  See `DESIGN.md` for the overall architecture and `application.ex` comments
  for the exact supervision ordering rationale.

  @phase 2 + 3
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FleetMonitorWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:fleet_monitor, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FleetMonitor.PubSub},
      # Phase 2 core infrastructure (per execution plan)
      # DeviceRegistry (API module) + explicit Registry child for reliable supervision (hygiene + boot compatibility)
      {Registry,
       keys: :unique, name: FleetMonitor.DeviceRegistry, partitions: System.schedulers_online()},
      FleetMonitor.MqttBridge,
      FleetMonitor.FleetState,
      # Centralized simulation timer — replaces the old decentralized per-device
      # `Process.send_after` timers. All devices now receive coordinated
      # `:simulation_tick` messages with a controllable `dt` (based on
      # simulated time * speed factor). This makes moisture/valve behavior
      # predictable and demo-tunable.
      FleetMonitor.SimulationTimer,
      # Phase 3: DynamicSupervisor for runtime device spawn/termination (Kill Node etc).
      # Static initial devices (below) remain for demo continuity; new ones via DeviceManager + this sup.
      FleetMonitor.DeviceSupervisor,
      # The Phoenix Endpoint must be in the supervision tree so that:
      # - mix phx.server (and releases with PHX_SERVER=true) start the HTTP server reliably
      # - The port from runtime.exs ($PORT) + dev loopback IP are honored consistently
      # - LiveView sockets, static assets, and code reloading work under normal OTP supervision
      FleetMonitorWeb.Endpoint,

      # libcluster Gossip configured (see cluster_topologies/0).
      # Supervisor child added in Phase 3 when multi-node demo ready.
      # For Phase 2 the dep + config satisfies "libcluster Gossip is configured (localhost at minimum)".
      # Three simulated devices (mix of types) started statically for demo continuity (Phase 2/3).
      # They auto-publish realistic physics-driven telemetry via MqttBridge -> MQTT -> PubSub.
      # Additional devices can be spawned dynamically at runtime via DeviceManager / UI (Phase 3).
      Supervisor.child_spec({FleetMonitor.Simulators.NervesPlant, [device_id: "nerves-001"]},
        id: :nerves_001
      ),
      {FleetMonitor.Simulators.Esp32Plant, [device_id: "esp32-042"]},
      Supervisor.child_spec({FleetMonitor.Simulators.NervesPlant, [device_id: "nerves-007"]},
        id: :nerves_007
      )
    ]

    opts = [strategy: :one_for_one, name: FleetMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FleetMonitorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
