defmodule FleetMonitor.MqttBridge do
  @moduledoc """
  Production-grade MQTT bridge GenServer (emqtt).

  The heart of the hybrid architecture (Phase 2):
  - Single supervised emqtt client for the entire console.
  - Subscribes to all device telemetry and status (LWT retained).
  - Publishes commands to devices over the universal MQTT bus.
  - On receipt, normalizes JSON and fans out via Phoenix.PubSub (distributed).
  - Respects v1/dt/fleet/plant/... topic schema exactly.
  - Handles reconnection, LWT birth/death certificates, retained status messages.
  - Structured logging via Logger.

  Simulators (both types) and real devices talk ONLY over MQTT to this bridge.
  Nerves clustered nodes may bypass for low-latency but still use MQTT for universality.

  Started by FleetMonitor.Application.
  """

  use GenServer
  require Logger

  @topic_prefix "v1"
  @fleet "fleet/plant"
  @dt_topic "#{@topic_prefix}/dt/#{@fleet}/"
  @cmd_topic "#{@topic_prefix}/cmd/#{@fleet}/"
  @status_topic "#{@topic_prefix}/status/#{@fleet}/"

  # Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Publish a command to a device. Used by LiveView actions (Phase 3+)."
  def publish_command(device_id, action, payload \\ %{}) when is_binary(device_id) do
    GenServer.call(__MODULE__, {:publish_cmd, device_id, action, payload})
  end

  @doc """
  Publish telemetry from a simulator (or real device) to the MQTT bus.
  For schema fidelity (§3.1): publishes per-metric topics
    v1/dt/fleet/plant/{id}/soil_moisture  -> {"value": 47.3, "unit":"%", "ts": ...}
  (and similarly for temperature/humidity/battery) **in addition to** the internal
  aggregate /sensors topic used for our PubSub roundtrip.
  This makes `mosquitto_sub` and external observers see the exact documented schema
  while keeping the demo LV working with no changes.
  """
  def publish_telemetry(device_id, metrics) when is_binary(device_id) and is_map(metrics) do
    GenServer.call(__MODULE__, {:publish_telemetry, device_id, metrics})
  end

  @doc "Publish per-device retained status (LWT/birth) for Phase 2 sims."
  def publish_status(device_id, status_map) when is_binary(device_id) and is_map(status_map) do
    GenServer.call(__MODULE__, {:publish_status, device_id, status_map})
  end

  @doc "Get bridge health for dashboard cluster panel."
  def health do
    GenServer.call(__MODULE__, :health)
  end

  # GenServer

  @impl true
  def init(_opts) do
    cfg = Application.get_env(:fleet_monitor, :mqtt, [])
    host = Keyword.get(cfg, :host, "localhost") |> to_charlist()
    port = Keyword.get(cfg, :port, 1883)
    prefix = Keyword.get(cfg, :client_id_prefix, "fleet_console")
    client_id = "#{prefix}-#{:rand.uniform(9999)}"

    state = %{
      client_pid: nil,
      host: host,
      port: port,
      client_id: client_id,
      connected: false,
      reconnect_attempts: 0,
      last_error: nil,
      subscriptions: [@dt_topic <> "#", @status_topic <> "#"]
    }

    Logger.info("MqttBridge starting", host: host, port: port, client_id: client_id)
    # Connect async so supervisor doesn't block
    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(
        {:publish_cmd, device_id, action, payload},
        _from,
        %{client_pid: pid, connected: true} = state
      )
      when is_pid(pid) do
    topic = @cmd_topic <> "#{device_id}/#{action}"
    json = Jason.encode!(payload)

    case :emqtt.publish(pid, topic, json, qos: 1, retain: false) do
      :ok ->
        Logger.info("command published", topic: topic, device: device_id, action: action)

      err ->
        Logger.warning("command publish failed (local delivery still proceeds)",
          topic: topic,
          error: inspect(err)
        )
    end

    # Always deliver locally via PubSub. Local simulators (and the console) must react
    # to commands for the demo to work even if the MQTT broker is down or reconnecting.
    # The emqtt publish is best-effort for the wire / external observers.
    Phoenix.PubSub.broadcast(
      FleetMonitor.PubSub,
      "fleet:commands",
      {:command_sent, device_id, action, payload}
    )

    {:reply, :ok, state}
  end

  def handle_call({:publish_cmd, device_id, action, payload}, _from, state) do
    # Still deliver the command locally even when not connected to the broker.
    Phoenix.PubSub.broadcast(
      FleetMonitor.PubSub,
      "fleet:commands",
      {:command_sent, device_id, action, payload}
    )

    {:reply, :ok, state}
  end

  def handle_call(
        {:publish_telemetry, device_id, metrics},
        _from,
        %{client_pid: pid, connected: true} = state
      )
      when is_pid(pid) do
    # 1. Wire publishes (best effort) for schema fidelity and external tools
    agg_topic = @dt_topic <> "#{device_id}/sensors"
    agg_payload = Jason.encode!(metrics)

    :emqtt.publish(pid, agg_topic, agg_payload, qos: 0, retain: false)

    ts = System.system_time(:millisecond)

    Enum.each(metrics, fn {key, val} ->
      metric_name = Atom.to_string(key)

      unit =
        case key do
          :soil_moisture -> "%"
          :temperature -> "C"
          :humidity -> "%"
          :battery -> "%"
          _ -> ""
        end

      per_topic = @dt_topic <> "#{device_id}/#{metric_name}"
      per_payload = Jason.encode!(%{value: val, unit: unit, ts: ts})

      case :emqtt.publish(pid, per_topic, per_payload, qos: 0, retain: false) do
        :ok -> :ok
        _ -> :ok
      end
    end)

    Logger.debug("telemetry published (per-metric + aggregate)", device: device_id)
    # fall through to local delivery below
    do_local_telemetry_broadcast(device_id, metrics, ts)
    {:reply, :ok, state}
  end

  def handle_call({:publish_telemetry, device_id, metrics}, _from, state) do
    # No broker connection — still deliver locally so the Fleet Console and
    # simulators continue to show live soil moisture / telemetry updates.
    ts = System.system_time(:millisecond)
    do_local_telemetry_broadcast(device_id, metrics, ts)
    {:reply, :ok, state}
  end

  def handle_call(
        {:publish_status, device_id, status_map},
        _from,
        %{client_pid: pid, connected: true} = state
      )
      when is_pid(pid) do
    topic = @status_topic <> device_id
    payload = Jason.encode!(status_map)

    case :emqtt.publish(pid, topic, payload, qos: 1, retain: true) do
      :ok ->
        Logger.info("device status published (retained)",
          device: device_id,
          state: status_map["state"] || status_map[:state]
        )

        {:reply, :ok, state}

      err ->
        {:reply, {:error, err}, state}
    end
  end

  def handle_call({:publish_status, _, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:health, _from, state) do
    {:reply,
     %{
       connected: state.connected,
       client_id: state.client_id,
       host: state.host,
       reconnects: state.reconnect_attempts,
       last_error: state.last_error
     }, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case do_connect(state) do
      {:ok, pid, new_state} ->
        {:noreply, %{new_state | client_pid: pid, connected: true, reconnect_attempts: 0}}

      {:error, reason, new_state} ->
        Logger.error("MQTT connect failed", reason: inspect(reason))
        schedule_reconnect(new_state.reconnect_attempts)
        {:noreply, %{new_state | connected: false, last_error: reason}}
    end
  end

  # emqtt delivers connection lifecycle as bare messages to the owner process
  # (the GenServer) after :emqtt.connect/1. Previously wrapped pattern was dead code.
  # Bare patterns + fallback log for diagnostics.
  def handle_info({:connected, _props}, state) do
    Logger.info("MQTT connected successfully", client: state.client_id)
    # Publish birth certificate (retained online status)
    birth = %{
      state: "online",
      type: "console",
      fw: "phase2",
      last_seen: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :emqtt.publish(state.client_pid, @status_topic <> "console", Jason.encode!(birth),
      qos: 1,
      retain: true
    )

    # Subscribe to telemetry + status (wildcards)
    Enum.each(state.subscriptions, fn t ->
      case :emqtt.subscribe(state.client_pid, t, qos: 1) do
        {:ok, _map, _list} -> Logger.debug("subscribed", topic: t)
        err -> Logger.warning("subscribe failed", topic: t, error: inspect(err))
      end
    end)

    {:noreply, %{state | connected: true}}
  end

  def handle_info({:disconnected, reason}, state) do
    Logger.warning("MQTT disconnected", reason: inspect(reason))
    schedule_reconnect(state.reconnect_attempts)
    {:noreply, %{state | connected: false, last_error: reason}}
  end

  # Fallback for any wrapped or unexpected emqtt message form (defensive)
  def handle_info({:emqtt, _pid, {:connected, props}}, state) do
    handle_info({:connected, props}, state)
  end

  def handle_info({:emqtt, _pid, {:disconnected, reason}}, state) do
    handle_info({:disconnected, reason}, state)
  end

  # Incoming publish from broker (the critical path for telemetry)
  def handle_info({:publish, packet}, state) do
    handle_incoming_publish(packet, state)
    {:noreply, state}
  end

  def handle_info({:reconnect, _}, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("unhandled mqtt info", msg: inspect(msg))
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{client_pid: pid}) when is_pid(pid) do
    # Publish offline LWT-like retained (best effort)
    if Process.alive?(pid) do
      offline = %{state: "offline", last_seen: DateTime.utc_now() |> DateTime.to_iso8601()}

      :emqtt.publish(pid, @status_topic <> "console", Jason.encode!(offline),
        qos: 1,
        retain: true
      )

      :emqtt.disconnect(pid)
    end
  end

  def terminate(_reason, _state), do: :ok

  # --- Private ---

  defp do_connect(state) do
    opts = [
      host: state.host,
      port: state.port,
      clientid: state.client_id,
      clean_start: false,
      # LWT: will be sent by broker if we die unclean
      will_topic: @status_topic <> "console",
      will_payload: Jason.encode!(%{state: "offline", reason: "disconnected"}),
      will_qos: 1,
      will_retain: true,
      keepalive: 30,
      # username/password if set
      username: Application.get_env(:fleet_monitor, :mqtt)[:username] || "",
      password: Application.get_env(:fleet_monitor, :mqtt)[:password] || ""
    ]

    case :emqtt.start_link(opts) do
      {:ok, pid} ->
        case :emqtt.connect(pid) do
          {:ok, _props} ->
            # The :connected message will arrive async
            {:ok, pid, %{state | reconnect_attempts: state.reconnect_attempts + 1}}

          err ->
            :emqtt.stop(pid)
            {:error, err, %{state | reconnect_attempts: state.reconnect_attempts + 1}}
        end

      err ->
        {:error, err, state}
    end
  end

  defp schedule_reconnect(attempts) do
    # Exponential backoff capped at 30s
    delay = min(30_000, 1000 * :math.pow(2, min(attempts, 5)))
    Process.send_after(self(), {:reconnect, attempts}, trunc(delay))
  end

  # Parse incoming telemetry/status and fan out to PubSub.
  # This is what the LiveView subscribes to.
  defp handle_incoming_publish(%{topic: topic, payload: payload, qos: _qos} = _pkt, _state) do
    cond do
      String.starts_with?(topic, @dt_topic) ->
        device_id = extract_device_id(topic, @dt_topic)
        rest = String.trim_leading(topic, @dt_topic)
        metric = List.last(String.split(rest, "/"))

        case Jason.decode(payload) do
          {:ok, data} when is_map(data) ->
            handle_dt_telemetry(device_id, metric, data)

          _ ->
            Logger.warning("bad telemetry json", topic: topic)
        end

      String.starts_with?(topic, @status_topic) ->
        device_id = extract_device_id(topic, @status_topic)

        case Jason.decode(payload) do
          {:ok, status} ->
            Phoenix.PubSub.broadcast(
              FleetMonitor.PubSub,
              "fleet:status",
              {:status, device_id, status}
            )

          _ ->
            :ok
        end

      true ->
        :ok
    end
  end

  # Handle data telemetry under v1/dt/... (both aggregate "sensors" and per-metric).
  defp handle_dt_telemetry(device_id, "sensors", data) do
    norm = normalize_metrics(data)

    Phoenix.PubSub.broadcast(
      FleetMonitor.PubSub,
      "fleet:telemetry",
      {:telemetry, device_id, norm, System.system_time(:millisecond)}
    )

    Logger.debug("telemetry received (aggregate)", device: device_id)
  end

  defp handle_dt_telemetry(device_id, metric, _data) do
    # Per-metric per §3.1 (e.g. /soil_moisture with {"value":.., "unit":.., "ts":..})
    # LOG-ONLY for Phase 2: do not broadcast partial maps (incompatible shape for FleetState/LV).
    # The aggregate /sensors path (emitted by our simulators) is the only source of state updates.
    # This keeps the demo table stable while still proving the exact schema is on the wire
    # (visible via mosquitto_sub). Real devices can adopt per-metric in Phase 3+.
    Logger.debug("per-metric telemetry on wire (schema compliant)",
      device: device_id,
      metric: metric
    )
  end

  # Always deliver telemetry to the local PubSub consumers (FleetState + LiveView).
  # This guarantees that soil moisture and other sensor values update in the console
  # for local simulators even when the MQTT broker is unavailable or reconnecting.
  # The wire (emqtt) path remains best-effort for external visibility.
  defp do_local_telemetry_broadcast(device_id, metrics, ts) do
    norm = normalize_metrics(metrics)

    Phoenix.PubSub.broadcast(
      FleetMonitor.PubSub,
      "fleet:telemetry",
      {:telemetry, device_id, norm, ts}
    )

    Logger.debug("telemetry delivered locally", device: device_id)
  end

  defp extract_device_id(topic, prefix) do
    # v1/dt/fleet/plant/{device_id}/metric  -> device_id
    rest = String.trim_leading(topic, prefix)

    case String.split(rest, "/", parts: 2) do
      [id | _] -> id
      _ -> "unknown"
    end
  end

  # exposed for test coverage only (Phase 2)
  @doc false
  def normalize_metrics(m) do
    # Accept both string and atom keys from JSON/simulators
    %{
      soil_moisture: get_num(m, ["soil_moisture", "soilMoisture", :soil_moisture]),
      temperature: get_num(m, ["temperature", :temperature]),
      humidity: get_num(m, ["humidity", :humidity]),
      battery: get_num(m, ["battery", :battery])
    }
  end

  defp get_num(map, keys) do
    Enum.find_value(keys, 0.0, fn k ->
      # Robust for both JSON-decoded (string keys) and our atom maps + per-metric
      find_first_numeric(map, key_candidates(k))
    end)
  end

  defp key_candidates(k), do: [k, to_string(k), String.to_atom(to_string(k))]

  defp find_first_numeric(map, candidates) do
    Enum.find_value(candidates, fn ck ->
      case Map.get(map, ck) do
        v when is_number(v) -> v * 1.0
        v when is_binary(v) -> parse_float_safe(v)
        _ -> nil
      end
    end)
  end

  defp parse_float_safe(v) do
    case Float.parse(v) do
      {f, _rest} -> f
      :error -> nil
    end
  end
end
