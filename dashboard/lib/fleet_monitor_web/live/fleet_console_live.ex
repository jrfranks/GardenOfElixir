defmodule FleetMonitorWeb.FleetConsoleLive do
  @moduledoc """
  Phase 3 Fleet Console LiveView — the heart of the interactive "Wow" experience.

  This module is the primary user-facing orchestrator. It is responsible for:

  - Rendering a responsive grid of `DeviceCard` components (gauges, controls, status).
  - Managing live subscriptions to telemetry, status, commands, and events.
  - Maintaining optimistic local state for immediate UI feedback while always
    reconciling against the authoritative `FleetState` (ETS) on telemetry arrival.
  - Driving the live event log via `Phoenix.LiveView.stream/3`.
  - Exposing the cluster health panel (real `Node.list()`, bridge health, last probe latency).
  - The improved roundtrip probe: per-device ⏱ in DeviceCard footers + global "Probe Random".
    Uses Commands.ping (zero side-effects) + hybrid path detection (direct vs mqtt) +
    measurement to authoritative telemetry confirmation. Educational demo of architecture.
    (Probe state machine extracted to `FleetMonitorWeb.Probes` — main LV is now thin delegate + orchestrator.)
  - Handling all user actions (Water Now, Toggle Auto, Simulate Low Battery, Kill Node,
    Add Device, per-device Probe for hybrid latency, etc.) and delegating to `Commands` / `DeviceManager`.
  - Bounded event log (capped at 180 entries) to prevent unbounded memory growth
    during long-running demos (remediation from review round).

  Architectural notes:
  - This LiveView deliberately uses a custom full-bleed industrial dark theme
    instead of the default `<Layouts.app>` to achieve the wide control-room feel.
    Flash messages are rendered via a minimal local container.
  - "Telemetry is the source of truth" is a core invariant. Optimistic updates
    exist only for perceived responsiveness.
  - All command paths go through the universal MQTT bus (via `MqttBridge`) for
    external observability, even though local simulators also receive them via
    PubSub for speed.

  See `DESIGN.md` for the full theory of the hybrid architecture and command flow.

  @phase 3
  """

  use FleetMonitorWeb, :live_view

  alias FleetMonitor.{Commands, DeviceManager, FleetState}
  alias FleetMonitorWeb.Components.DeviceCard
  alias FleetMonitorWeb.Probes

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FleetMonitor.PubSub, "fleet:telemetry")
      Phoenix.PubSub.subscribe(FleetMonitor.PubSub, "fleet:status")
      Phoenix.PubSub.subscribe(FleetMonitor.PubSub, "fleet:commands")
      Phoenix.PubSub.subscribe(FleetMonitor.PubSub, "fleet:events")
    end

    devices = FleetState.get_all_devices()

    socket =
      socket
      |> assign(:page_title, "Fleet Console — Phase 3")
      # live event log via stream (perf for Phase 3)
      |> stream(:events, [])
      |> assign(:devices, devices)
      |> assign(:bridge_health, FleetMonitor.MqttBridge.health())
      |> assign(:last_update, System.system_time(:millisecond))
      |> assign(:cluster_nodes, Node.list())
      |> assign(:roundtrip_ms, nil)
      |> assign(:pending_probes, %{})
      |> assign(:roundtrips, %{})
      |> assign(:add_error, nil)
      |> assign(:event_count, 0)
      # Phase 3 remediation (review #5): bound the log to prevent unbounded growth
      |> assign(:max_events, 180)

    {:ok, socket}
  end

  @impl true
  def handle_info({:telemetry, device_id, metrics, ts}, socket) do
    # Update devices (source of truth from real telemetry)
    current = socket.assigns.devices

    # Phase 3 remediation (review #2): reconcile from authoritative FleetState (telemetry + status is truth)
    # Prevents optimistic desync on races / auto decisions / kill. Merge fresh metrics over ETS record.
    authoritative =
      FleetState.get_device(device_id) ||
        %{id: device_id, type: infer_type(device_id), status: %{}, metrics: %{}}

    dev =
      authoritative
      |> Map.put(:metrics, metrics)
      |> Map.put(:last_seen, ts)
      |> Map.put(:online, true)

    devices = Map.put(current, device_id, dev)

    # Live event (color green for telemetry)
    event = %{
      id: "evt-#{System.unique_integer([:positive])}",
      ts: ts,
      kind: :telemetry,
      device_id: device_id,
      msg:
        "telemetry update (#{Float.round(get_in(metrics, [:soil_moisture]) || 0, 1)}% moisture)"
    }

    socket =
      socket
      |> assign(:devices, devices)
      |> assign(:last_update, ts)
      # append (capped)
      |> stream_event(event)
      |> Probes.maybe_complete_probe(device_id, System.monotonic_time(:millisecond))

    {:noreply, socket}
  end

  def handle_info({:status, device_id, status}, socket) do
    current = socket.assigns.devices

    existing =
      Map.get(current, device_id, %{id: device_id, type: infer_type(device_id), metrics: %{}})

    dev =
      existing
      |> Map.put(:status, Map.merge(Map.get(existing, :status, %{}), normalize_status(status)))
      |> Map.put(:online, status_online?(status))
      |> Map.put(:last_seen, System.system_time(:millisecond))

    devices = Map.put(current, device_id, dev)

    kind = if status_online?(status), do: :birth, else: :death

    event = %{
      id: "evt-#{System.unique_integer([:positive])}",
      ts: System.system_time(:millisecond),
      kind: kind,
      device_id: device_id,
      msg: "status #{inspect(status)}"
    }

    {:noreply,
     socket
     |> assign(:devices, devices)
     |> stream_insert(:events, event, at: -1)}
  end

  def handle_info({:command_sent, device_id, action, payload}, socket) do
    # Command echo from bridge (blue in log)
    event = %{
      id: "evt-#{System.unique_integer([:positive])}",
      ts: System.system_time(:millisecond),
      kind: :command,
      device_id: device_id,
      msg: "command #{action} sent #{inspect_compact(payload)}"
    }

    # (Probe measurement now happens on authoritative telemetry confirmation in the
    # {:telemetry, ...} handler for the improved side-effect-free ping path.)
    socket =
      socket
      |> stream_insert(:events, event, at: -1)

    {:noreply, socket}
  end

  def handle_info({:device_born, device_id, type}, socket) do
    event = %{
      id: "evt-#{System.unique_integer([:positive])}",
      ts: System.system_time(:millisecond),
      kind: :birth,
      device_id: device_id,
      msg: "device born (#{type})"
    }

    {:noreply, stream_insert(socket, :events, event, at: -1)}
  end

  def handle_info({:device_killed, device_id}, socket) do
    devices = Map.delete(socket.assigns.devices, device_id)

    # Clean probe state to avoid leaks on rapid kill/expiry
    # (defensive hygiene from past review learnings on optimistic vs authoritative)
    # Any pending timer_ref is dropped without explicit cancel; the exact-match
    # guard in Probes.handle_probe_timeout will safely ignore the late {:probe_timeout} message.
    pending_probes = Map.delete(socket.assigns.pending_probes, device_id)
    roundtrips = Map.delete(socket.assigns.roundtrips, device_id)

    event = %{
      id: "evt-#{System.unique_integer([:positive])}",
      ts: System.system_time(:millisecond),
      kind: :death,
      device_id: device_id,
      msg: "killed (LWT offline sent)"
    }

    {:noreply,
     socket
     |> assign(:devices, devices)
     |> assign(:pending_probes, pending_probes)
     |> assign(:roundtrips, roundtrips)
     |> stream_insert(:events, event, at: -1)}
  end

  # Probe timeout (defensive; clears "probing..." if no telemetry confirmation in ~1.8s)
  # Delegates to Probes for the exact-match hygiene logic (extracted to shrink orchestrator).
  def handle_info({:probe_timeout, device_id, sent_at}, socket) do
    pending = Probes.handle_probe_timeout(socket.assigns.pending_probes, device_id, sent_at)
    {:noreply, assign(socket, :pending_probes, pending)}
  end

  def handle_info(:refresh_cluster, socket) do
    {:noreply,
     socket
     |> assign(:cluster_nodes, Node.list())
     |> assign(:bridge_health, FleetMonitor.MqttBridge.health())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # --- Event handlers for all Phase 3 controls (optimistic + real path) ---

  @impl true
  def handle_event("water_now", %{"device_id" => raw_id}, socket) do
    # Phase 3 remediation (review #3): guard + sanitize (demo allow-list + injection prevention)
    id = sanitize_device_id(raw_id)
    devices = socket.assigns.devices

    if id == nil or not known_device?(id, devices) do
      {:noreply, put_flash(socket, :error, "Unknown or invalid device")}
    else
      # Optimistic: show valve open immediately in local state
      devices =
        optimistic_update(devices, id, fn dev ->
          put_in(dev, [:status, :valve_open], true)
        end)

      # duration=0 means "water until Auto High level is reached" (new target-based behavior)
      Commands.water_now(id, 0)

      event = %{
        id: "evt-#{System.unique_integer([:positive])}",
        ts: System.system_time(:millisecond),
        kind: :command,
        device_id: id,
        msg: "WATER NOW (optimistic)"
      }

      {:noreply,
       socket
       |> assign(:devices, devices)
       |> stream_insert(:events, event, at: -1)}
    end
  end

  def handle_event("stop_water", %{"device_id" => raw_id}, socket) do
    id = sanitize_device_id(raw_id)
    devices = socket.assigns.devices

    if id == nil or not known_device?(id, devices) do
      {:noreply, put_flash(socket, :error, "Unknown or invalid device")}
    else
      # Optimistic: close valve immediately
      devices =
        optimistic_update(devices, id, fn dev ->
          put_in(dev, [:status, :valve_open], false)
        end)

      Commands.stop_water(id)

      event = %{
        id: "evt-#{System.unique_integer([:positive])}",
        ts: System.system_time(:millisecond),
        kind: :command,
        device_id: id,
        msg: "STOP WATERING"
      }

      {:noreply,
       socket
       |> assign(:devices, devices)
       |> stream_insert(:events, event, at: -1)}
    end
  end

  def handle_event("toggle_auto", %{"device_id" => raw_id, "enabled" => enabled_str}, socket) do
    id = sanitize_device_id(raw_id)
    devices_map = socket.assigns.devices

    if id == nil or not known_device?(id, devices_map) do
      {:noreply, put_flash(socket, :error, "Unknown or invalid device")}
    else
      enabled = enabled_str == "true"

      devices =
        optimistic_update(devices_map, id, fn dev ->
          put_in(dev, [:status, :auto_mode], enabled)
        end)

      Commands.set_auto_mode(id, enabled)

      event = %{
        id: "evt-#{System.unique_integer([:positive])}",
        ts: System.system_time(:millisecond),
        kind: :command,
        device_id: id,
        msg: "set auto_mode=#{enabled}"
      }

      {:noreply,
       socket
       |> assign(:devices, devices)
       |> stream_insert(:events, event, at: -1)}
    end
  end

  def handle_event("set_moisture_thresholds", %{"device_id" => raw_id} = params, socket) do
    id = sanitize_device_id(raw_id)
    devices_map = socket.assigns.devices

    if id == nil or not known_device?(id, devices_map) do
      {:noreply, put_flash(socket, :error, "Unknown or invalid device")}
    else
      device = Map.get(devices_map, id)

      current_low = get_in(device, [:status, :moisture_low]) || 18.0
      current_high = get_in(device, [:status, :moisture_high]) || 52.0

      min_gap = 3.0

      raw_low = Map.get(params, "low") |> parse_float_or(current_low)
      raw_high = Map.get(params, "high") |> parse_float_or(current_high)

      # Strong validation: always enforce low + gap <= high
      low = min(raw_low, raw_high - min_gap) |> max(0.0)
      high = max(raw_high, low + min_gap) |> min(100.0)

      devices =
        optimistic_update(devices_map, id, fn dev ->
          dev
          |> put_in([:status, :moisture_low], low)
          |> put_in([:status, :moisture_high], high)
        end)

      Commands.set_moisture_thresholds(id, low, high)

      {:noreply, assign(socket, :devices, devices)}
    end
  end

  def handle_event("set_telemetry_interval", %{"device_id" => raw_id} = params, socket) do
    id = sanitize_device_id(raw_id)
    devices_map = socket.assigns.devices

    if id == nil or not known_device?(id, devices_map) do
      {:noreply, put_flash(socket, :error, "Unknown or invalid device")}
    else
      current = get_in(devices_map, [id, :status, :report_interval_closed_ms]) || 60_000

      raw_interval = Map.get(params, "interval_ms") |> parse_integer_or(current)
      # 5s to 5min
      interval = max(5_000, min(300_000, raw_interval))

      devices =
        optimistic_update(devices_map, id, fn dev ->
          put_in(dev, [:status, :report_interval_closed_ms], interval)
        end)

      Commands.set_telemetry_interval(id, interval)

      {:noreply, assign(socket, :devices, devices)}
    end
  end

  def handle_event("simulate_low_battery", %{"device_id" => raw_id}, socket) do
    id = sanitize_device_id(raw_id)
    devices_map = socket.assigns.devices

    if id == nil or not known_device?(id, devices_map) do
      {:noreply, put_flash(socket, :error, "Unknown or invalid device")}
    else
      devices =
        optimistic_update(devices_map, id, fn dev ->
          put_in(dev, [:metrics, :battery], 7.0)
        end)

      Commands.simulate_low_battery(id)

      event = %{
        id: "evt-#{System.unique_integer([:positive])}",
        ts: System.system_time(:millisecond),
        kind: :warning,
        device_id: id,
        msg: "simulate low battery"
      }

      {:noreply,
       socket
       |> assign(:devices, devices)
       |> stream_insert(:events, event, at: -1)}
    end
  end

  def handle_event("kill_node", %{"device_id" => raw_id}, socket) do
    id = sanitize_device_id(raw_id)
    devices_map = socket.assigns.devices

    if id == nil or not known_device?(id, devices_map) do
      {:noreply, put_flash(socket, :error, "Unknown or invalid device")}
    else
      # Optimistic remove + LWT via manager
      devices = Map.delete(devices_map, id)
      DeviceManager.stop_device(id)

      event = %{
        id: "evt-#{System.unique_integer([:positive])}",
        ts: System.system_time(:millisecond),
        kind: :death,
        device_id: id,
        msg: "KILL initiated (LWT + terminate)"
      }

      {:noreply,
       socket
       |> assign(:devices, devices)
       |> stream_insert(:events, event, at: -1)}
    end
  end

  def handle_event("add_device", %{"type" => type_str}, socket) do
    type = if type_str == "esp32", do: :esp32, else: :nerves
    id = "#{type_str}-#{:rand.uniform(899) + 100}"

    case DeviceManager.start_device(type, id) do
      {:ok, _pid} ->
        # Device will birth via status + telemetry shortly
        {:noreply, assign(socket, :add_error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :add_error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("measure_roundtrip", _params, socket) do
    # Global convenience: probe a random device (kept for demo UX; per-card Probes are primary)
    case find_any_device_id(socket.assigns.devices) do
      nil ->
        {:noreply, socket |> put_flash(:info, "No devices yet")}

      raw_id ->
        # Mirror the guarded surface used by "probe_device" for consistency
        # (sanitize + known_device? allow-list before any Probes/Commands call).
        id = sanitize_device_id(raw_id)

        if id == nil or not known_device?(id, socket.assigns.devices) do
          {:noreply, put_flash(socket, :error, "Unknown or invalid device")}
        else
          updated = Probes.initiate_probe(id, socket, flash: true)
          {:noreply, updated}
        end
    end
  end

  def handle_event("probe_device", %{"device_id" => raw_id}, socket) do
    # Per-device probe (primary UX in DeviceCard footer). Uses lightweight ping + hybrid path.
    id = sanitize_device_id(raw_id)

    if id == nil or not known_device?(id, socket.assigns.devices) do
      {:noreply, put_flash(socket, :error, "Unknown or invalid device")}
    else
      updated = Probes.initiate_probe(id, socket, flash: false)
      {:noreply, updated}
    end
  end

  def handle_event("clear_log", _params, socket) do
    {:noreply,
     socket
     |> stream(:events, [], reset: true)
     |> assign(:event_count, 0)}
  end

  # --- Render: full Phase 3 flashy console (dark industrial, responsive grid) ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950 text-zinc-200 p-4 md:p-6 font-mono">
      <header class="mb-6 border-b border-zinc-800 pb-4">
        <div class="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-2">
          <div>
            <h1 class="text-4xl font-bold tracking-tighter">🌱 Fleet Console</h1>
            <p class="text-emerald-400 text-sm">Phase 3 — Interactive Hybrid IoT Command Center</p>
          </div>
          <div class="text-xs text-zinc-500">
            MQTT + Distributed Erlang • {if @bridge_health.connected,
              do: "BRIDGE OK",
              else: "BRIDGE RECONNECTING"}
          </div>
        </div>
      </header>
      
    <!-- Phase 3 remediation (review #2): minimal visible flash container so put_flash feedback (e.g. roundtrip) is not invisible.
           Avoids full <Layouts.app> (would constrain grid width and contradict existing Phase 2 console pattern). -->
      <%= if info = Phoenix.Flash.get(@flash, :info) do %>
        <div class="mb-3 px-3 py-1.5 bg-emerald-900/70 border border-emerald-800 text-emerald-200 text-xs rounded">
          {info}
        </div>
      <% end %>
      <%= if err = Phoenix.Flash.get(@flash, :error) do %>
        <div class="mb-3 px-3 py-1.5 bg-red-900/70 border border-red-800 text-red-200 text-xs rounded">
          {err}
        </div>
      <% end %>
      
    <!-- Global actions + Cluster Health -->
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4 mb-6">
        <div class="lg:col-span-2">
          <div class="flex flex-wrap gap-2">
            <button
              phx-click="add_device"
              phx-value-type="nerves"
              class="btn btn-sm btn-outline border-emerald-700 text-emerald-300"
            >
              + Spawn Nerves Sim
            </button>
            <button
              phx-click="add_device"
              phx-value-type="esp32"
              class="btn btn-sm btn-outline border-amber-700 text-amber-300"
            >
              + Spawn ESP32 Sim
            </button>
            <button phx-click="measure_roundtrip" class="btn btn-sm btn-secondary">
              ⏱ Probe Random
            </button>
            <button phx-click="clear_log" class="btn btn-sm btn-ghost">Clear Log</button>
            <%= if @add_error do %>
              <span class="text-red-400 text-xs self-center">{@add_error}</span>
            <% end %>
          </div>
        </div>
        
    <!-- Cluster Health (real BEAM metrics) -->
        <div class="card bg-zinc-900 border border-zinc-800 p-3 text-xs">
          <div class="font-semibold text-emerald-300 mb-1">CLUSTER HEALTH</div>
          <div class="flex gap-x-4 gap-y-0.5 flex-wrap">
            <div>BEAM nodes: <span class="font-semibold">{length(@cluster_nodes) + 1}</span></div>
            <div>
              MQTT:
              <span class={
                if @bridge_health.connected, do: "text-emerald-400", else: "text-amber-400"
              }>
                {if @bridge_health.connected, do: "connected", else: "down"}
              </span>
            </div>
            <div>
              Last probe:
              <span class="font-semibold tabular-nums">
                {if @roundtrip_ms, do: "#{@roundtrip_ms}ms", else: "—"}
              </span>
            </div>
            <div class="text-zinc-500">Devices: {map_size(@devices)}</div>
          </div>
          <div class="text-[10px] text-zinc-500 mt-1 truncate">
            Nodes: self + {Enum.join(@cluster_nodes, ", ")}
          </div>
        </div>
      </div>
      
    <!-- Device Grid (the star) -->
      <div class="mb-4">
        <h2 class="text-sm uppercase tracking-widest text-emerald-300/80 mb-3">
          Active Fleet — Live Gauges & Controls
        </h2>

        <%= if map_size(@devices) == 0 do %>
          <div class="p-8 text-center border border-dashed border-zinc-800 rounded-2xl text-zinc-500">
            No devices yet. Simulators starting or use Spawn buttons above.
          </div>
        <% else %>
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
            <%= for {id, dev} <- @devices do %>
              <DeviceCard.device_card
                device={dev}
                probing={Map.has_key?(@pending_probes || %{}, id)}
                roundtrip={Map.get(@roundtrips || %{}, id)}
              />
            <% end %>
          </div>
        <% end %>
      </div>
      
    <!-- Live Event Log (stream) -->
      <div>
        <div class="flex items-center justify-between mb-2">
          <h2 class="text-sm uppercase tracking-widest text-emerald-300/80">Live Event Log</h2>
          <span class="text-[10px] text-zinc-500">auto-scroll • color coded</span>
        </div>

        <div
          id="event-log"
          phx-update="stream"
          class="h-64 overflow-auto rounded-2xl border border-zinc-800 bg-zinc-950 p-3 text-xs font-mono space-y-1"
        >
          <div
            :for={{id, evt} <- @streams.events}
            id={id}
            class="flex gap-2 items-start border-b border-zinc-900 pb-0.5 last:border-0"
          >
            <span class="text-zinc-500 tabular-nums w-16 flex-shrink-0">{format_log_ts(evt.ts)}</span>
            <span class={[
              "px-1.5 py-px rounded text-[9px] font-bold uppercase flex-shrink-0",
              event_kind_class(evt.kind)
            ]}>
              {evt.kind}
            </span>
            <span class="text-emerald-300 flex-shrink-0">{evt.device_id}</span>
            <span class="text-zinc-300 flex-1 truncate">{evt.msg}</span>
          </div>
          <div :if={@event_count == 0} class="text-zinc-500 p-2">
            Waiting for events (telemetry, commands, births, LWTs)...
          </div>
        </div>
      </div>

      <div class="mt-6 text-[10px] text-zinc-500 max-w-prose">
        Commands flow: UI → Commands → MqttBridge.publish (MQTT) → broker → sims (PubSub) → physics update → telemetry → FleetState → UI (confirm).<br />
        Kill uses DynamicSupervisor + LWT retained status. Dynamic spawn uses DeviceSupervisor.<br />
        <span class="text-amber-400">
          Demo only: unauthenticated command surface (allow-list guarded). Portfolio / local use. See device_manager + LV for hardening notes.
        </span>
      </div>
    </div>
    """
  end

  # --- Small private helpers (follow existing patterns, safe parsing) ---

  # Phase 3 remediation (review #3 High): demo-only allow-list guard against unauth command dispatch.
  # Rejects unknown device_ids (prevents targeting arbitrary strings / topic injection via crafted events).
  # In real deployment would be authz + ACLs at MQTT + LV session.
  defp parse_float_or(nil, default), do: default

  defp parse_float_or(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_float_or(val, _default) when is_number(val), do: val * 1.0
  defp parse_float_or(_, default), do: default

  defp parse_integer_or(nil, default), do: default

  defp parse_integer_or(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} -> i
      :error -> default
    end
  end

  defp parse_integer_or(val, _default) when is_number(val), do: round(val)
  defp parse_integer_or(_, default), do: default

  defp known_device?(id, devices) when is_binary(id) and is_map(devices) do
    Map.has_key?(devices, id) or FleetState.get_device(id) != nil
  end

  defp known_device?(_, _), do: false

  defp sanitize_device_id(id) when is_binary(id) do
    if String.contains?(id, ["/", " ", "\n", "\0"]) or byte_size(id) > 32, do: nil, else: id
  end

  defp sanitize_device_id(_), do: nil

  # Bounded event log helper (review #5) — caps stream to avoid memory blowup in long demo runs.
  defp stream_event(socket, event) do
    count = socket.assigns[:event_count] || 0
    maxe = socket.assigns[:max_events] || 180

    socket =
      if count > maxe do
        # Prune by reset (demo log; acceptable; keeps recent activity)
        stream(socket, :events, [], reset: true)
        |> assign(:event_count, 0)
      else
        socket
      end
      |> stream_insert(:events, event, at: -1)
      |> assign(:event_count, min(count + 1, maxe + 10))

    socket
  end

  defp infer_type(id) do
    cond do
      String.contains?(to_string(id), "nerves") -> "nerves"
      String.contains?(to_string(id), "esp32") -> "esp32"
      true -> "sim"
    end
  end

  defp optimistic_update(devices, id, fun) when is_map(devices) do
    case Map.get(devices, id) do
      nil -> devices
      dev -> Map.put(devices, id, fun.(dev))
    end
  end

  defp normalize_status(status) when is_map(status) do
    # Mirror the rich fields that the authoritative FleetState keeps.
    # Only include optional config keys when present in the payload so that
    # status messages carrying only valve/auto do not clear thresholds etc.
    base = %{
      valve_open: get_in(status, ["valve_open"]) || get_in(status, [:valve_open]) || false,
      auto_mode: get_in(status, ["auto_mode"]) || get_in(status, [:auto_mode]) || true
    }

    base =
      case get_in(status, ["moisture_low"]) || get_in(status, [:moisture_low]) ||
             get_in(status, ["moistureLow"]) do
        nil -> base
        v -> Map.put(base, :moisture_low, v)
      end

    base =
      case get_in(status, ["moisture_high"]) || get_in(status, [:moisture_high]) ||
             get_in(status, ["moistureHigh"]) do
        nil -> base
        v -> Map.put(base, :moisture_high, v)
      end

    base =
      case get_in(status, ["report_interval_closed_ms"]) ||
             get_in(status, [:report_interval_closed_ms]) do
        nil -> base
        v -> Map.put(base, :report_interval_closed_ms, v)
      end

    base =
      case get_in(status, ["water_to_target"]) || get_in(status, [:water_to_target]) do
        nil -> base
        v -> Map.put(base, :water_to_target, v)
      end

    base
  end

  defp normalize_status(_), do: %{}

  defp status_online?(status) do
    case status do
      %{"state" => s} -> s != "offline"
      %{state: s} -> s != "offline"
      _ -> true
    end
  end

  defp inspect_compact(m) when is_map(m), do: inspect(m, limit: 3)
  defp inspect_compact(v), do: inspect(v)

  defp find_any_device_id(devices) when map_size(devices) > 0 do
    devices |> Map.keys() |> List.first()
  end

  defp find_any_device_id(_), do: nil

  # Probe logic extracted to FleetMonitorWeb.Probes (see moduledoc for details).

  defp event_kind_class(:telemetry), do: "bg-emerald-900 text-emerald-300"
  defp event_kind_class(:command), do: "bg-blue-900 text-blue-300"
  defp event_kind_class(:birth), do: "bg-purple-900 text-purple-300"
  defp event_kind_class(:death), do: "bg-red-900 text-red-300"
  defp event_kind_class(:warning), do: "bg-orange-900 text-orange-300"
  defp event_kind_class(_), do: "bg-zinc-800 text-zinc-400"

  defp format_log_ts(ts) when is_integer(ts) do
    # simple mm:ss
    secs = div(rem(ts, 3_600_000), 1000)
    :io_lib.format("~2..0B:~2..0B", [div(secs, 60), rem(secs, 60)]) |> to_string()
  end

  defp format_log_ts(_), do: "--:--"
end
