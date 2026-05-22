defmodule FleetMonitorWeb.Components.DeviceCard do
  @moduledoc """
  Phase 3 Device Card function component (pure Tailwind + CSS, daisyUI accents).
  No external JS; smooth CSS transitions for gauges.
  Renders metrics, valve state, primary actions (Water Now, Auto toggle), footer actions.
  Buttons emit phx events with phx-value-device_id for parent LiveView.

  Supports optional per-device probe state (probing + roundtrip result) for the
  improved side-effect-free hybrid latency probe feature. Display is subtle and
  non-blocking; badge shows ms + path (:direct for local Erlang, :mqtt otherwise).
  """

  use Phoenix.Component
  import FleetMonitorWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders one device card.

  Expects:
    - device: the FleetState map %{id, type, metrics, status, last_seen, online}
    - myself: the LiveView pid or nil (for targeting if needed, unused in Phase 3)
    - probing: boolean (optional) — shows "probing..." while a ping is in flight
    - roundtrip: map or nil — %{ms: integer, path: :direct | :mqtt, measured_at: ts} for badge
  """
  attr :device, :map, required: true
  attr :myself, :any, default: nil
  attr :probing, :boolean, default: false
  attr :roundtrip, :map, default: nil

  def device_card(assigns) do
    ~H"""
    <div class="card bg-zinc-900 border border-zinc-800 shadow-xl rounded-2xl overflow-hidden flex flex-col transition-all hover:border-emerald-900/50">
      <!-- Header -->
      <div class="px-4 py-3 bg-zinc-950 border-b border-zinc-800 flex items-center justify-between">
        <div class="flex items-center gap-2 min-w-0">
          <div class={[
            "w-2.5 h-2.5 rounded-full flex-shrink-0",
            if(@device[:online], do: "bg-emerald-400 animate-pulse", else: "bg-red-500")
          ]} />
          <div class="font-mono font-semibold text-sm truncate">{@device[:id] || "unknown"}</div>
        </div>

        <div class="flex items-center gap-2">
          <span class={[
            "px-2 py-0.5 text-[10px] font-medium rounded-full border",
            if(@device[:type] == "nerves",
              do: "bg-blue-950/70 text-blue-300 border-blue-900",
              else: "bg-amber-950/70 text-amber-300 border-amber-900"
            )
          ]}>
            {@device[:type] || "sim"}
          </span>
          <span class="text-[10px] text-zinc-500 tabular-nums">
            {format_last_seen(@device[:last_seen])}
          </span>
        </div>
      </div>
      
    <!-- Metrics -->
      <div class="p-4 space-y-4">
        <!-- Soil Moisture -->
        <div>
          <div class="flex justify-between text-xs mb-1">
            <span class="text-emerald-400 font-medium">Soil Moisture</span>
            <span class="font-mono tabular-nums font-semibold">
              {format_pct(get_metric(@device, :soil_moisture))}
            </span>
          </div>

          <% low = get_in(@device, [:status, :moisture_low]) || 18.0 %>
          <% high = get_in(@device, [:status, :moisture_high]) || 52.0 %>
          <% auto_on = auto_mode?(@device) %>

          <div class="relative h-2.5 bg-zinc-800 rounded-full overflow-hidden">
            <!-- Moisture fill -->
            <div
              class="h-2.5 rounded-full transition-all duration-500 ease-out"
              style={"width: #{gauge_width(get_metric(@device, :soil_moisture))}% ; background: linear-gradient(to right, #10b981, #eab308);"}
            />
            
    <!-- Auto threshold markers (only when Auto is enabled) -->
            <%= if auto_on do %>
              <!-- Low threshold marker -->
              <div
                class="absolute top-0 bottom-0 w-0.5 bg-red-400 z-10"
                style={"left: #{gauge_width(low)}%;"}
                title={"Auto Low: #{Float.round(low)}%"}
                data-role="low-marker"
              />
              <!-- High threshold marker -->
              <div
                class="absolute top-0 bottom-0 w-0.5 bg-blue-400 z-10"
                style={"left: #{gauge_width(high)}%;"}
                title={"Auto High: #{Float.round(high)}%"}
                data-role="high-marker"
              />
            <% end %>
          </div>
          
    <!-- Auto threshold sliders (shown only when Auto is ON) -->
          <%= if auto_on do %>
            <% min_gap = 3.0 %>
            <div
              id={"moisture-thresholds-#{@device[:id]}"}
              phx-hook="MoistureThresholds"
              data-device-id={@device[:id]}
              data-gap={min_gap}
              class="mt-2"
            >
              <!-- Visual markers on the bar (already rendered above) -->

              <!-- Sliders -->
              <div class="grid grid-cols-2 gap-x-3 text-[10px]">
                <!-- Low -->
                <div>
                  <div class="flex justify-between text-red-400">
                    <span>Auto Low</span>
                    <span data-role="low-value" class="font-mono">{Float.round(low)}%</span>
                  </div>
                  <input
                    type="range"
                    min="0"
                    max="100"
                    step="0.5"
                    value={low}
                    name="low"
                    data-role="low-slider"
                    class="w-full accent-red-400 h-1.5"
                  />
                </div>
                
    <!-- High -->
                <div>
                  <div class="flex justify-between text-blue-400">
                    <span>Auto High</span>
                    <span data-role="high-value" class="font-mono">{Float.round(high)}%</span>
                  </div>
                  <input
                    type="range"
                    min="0"
                    max="100"
                    step="0.5"
                    value={high}
                    name="high"
                    data-role="high-slider"
                    class="w-full accent-blue-400 h-1.5"
                  />
                </div>
              </div>
            </div>
          <% end %>
        </div>
        
    <!-- Idle Telemetry Rate (dynamic update frequency when valve closed) -->
        <% idle_ms = get_in(@device, [:status, :report_interval_closed_ms]) || 60_000 %>
        <% idle_sec = round(idle_ms / 1000) %>

        <div
          id={"telemetry-interval-#{@device[:id]}"}
          phx-hook="TelemetryInterval"
          data-device-id={@device[:id]}
          class="mt-2.5"
        >
          <div class="flex justify-between text-[10px] mb-0.5">
            <span class="text-violet-400">Idle telemetry</span>
            <span data-role="interval-value" class="font-mono text-violet-300">{idle_sec}s</span>
          </div>
          <input
            type="range"
            min="5000"
            max="120000"
            step="5000"
            value={idle_ms}
            data-role="interval-slider"
            class="w-full accent-violet-400 h-1.5"
          />
          <div class="flex justify-between text-[8px] text-zinc-500 -mt-0.5">
            <span>fast (4/min when watering)</span>
            <span>slow</span>
          </div>
        </div>
        
    <!-- Temperature -->
        <div>
          <div class="flex justify-between text-xs mb-1">
            <span class="text-orange-400 font-medium">Temperature</span>
            <span class="font-mono tabular-nums">
              {format_temp(get_metric(@device, :temperature))}
            </span>
          </div>
          <div class="h-2 bg-zinc-800 rounded-full overflow-hidden">
            <div
              class="h-2 rounded-full transition-all duration-500"
              style={"width: #{gauge_width(get_metric(@device, :temperature), 0, 40)}%; background: #f59e0b;"}
            />
          </div>
        </div>
        
    <!-- Humidity -->
        <div>
          <div class="flex justify-between text-xs mb-1">
            <span class="text-sky-400 font-medium">Humidity</span>
            <span class="font-mono tabular-nums">
              {format_pct(get_metric(@device, :humidity))}
            </span>
          </div>
          <div class="h-2 bg-zinc-800 rounded-full overflow-hidden">
            <div
              class="h-2 rounded-full transition-all duration-500 bg-sky-400"
              style={"width: #{gauge_width(get_metric(@device, :humidity))}%"}
            />
          </div>
        </div>
        
    <!-- Battery -->
        <div>
          <div class="flex justify-between text-xs mb-1 items-center">
            <span class="text-amber-400 font-medium flex items-center gap-1">
              <.icon name="hero-bolt" class="size-3" /> Battery
            </span>
            <span class="font-mono tabular-nums">
              {format_pct(get_metric(@device, :battery))}
            </span>
          </div>
          <div class="h-2 bg-zinc-800 rounded-full overflow-hidden">
            <div
              class={[
                "h-2 rounded-full transition-all duration-500",
                battery_color_class(get_metric(@device, :battery))
              ]}
              style={"width: #{gauge_width(get_metric(@device, :battery))}%"}
            />
          </div>
        </div>
      </div>
      
    <!-- Valve + Controls -->
      <div class="px-4 pb-4 pt-2 border-t border-zinc-800 bg-zinc-950/50">
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-2 text-sm">
            <span class="text-zinc-400">Valve:</span>
            <span class={[
              "font-semibold px-2 py-0.5 rounded text-xs",
              if(valve_open?(@device),
                do: "bg-emerald-500/20 text-emerald-300",
                else: "bg-zinc-700 text-zinc-400"
              )
            ]}>
              {if valve_open?(@device), do: "OPEN", else: "CLOSED"}
            </span>
          </div>

          <div class="text-xs text-zinc-500">
            Auto:
            <span class={if auto_mode?(@device), do: "text-emerald-400", else: "text-zinc-400"}>
              {if auto_mode?(@device), do: "ON", else: "OFF"}
            </span>
          </div>
        </div>
        
    <!-- Probe status (improved latency probe UI — subtle, per-device) -->
        <%= if @probing do %>
          <div class="text-[10px] text-amber-400 mb-2">⏱ probing...</div>
        <% else %>
          <%= if rt = @roundtrip do %>
            <div class={[
              "text-[10px] font-mono mb-2 tabular-nums",
              if(rt.path == :direct, do: "text-emerald-400", else: "text-amber-400")
            ]}>
              ⏱ {rt.ms} ms ({rt.path})
            </div>
          <% end %>
        <% end %>
        
    <!-- Primary actions -->
        <div class="flex gap-2">
          <%= if valve_open?(@device) do %>
            <button
              phx-click="stop_water"
              phx-value-device_id={@device[:id]}
              class="flex-1 btn btn-sm btn-error text-xs"
              disabled={not @device[:online]}
            >
              ⏹ Stop Watering
            </button>
          <% else %>
            <button
              phx-click="water_now"
              phx-value-device_id={@device[:id]}
              class="flex-1 btn btn-sm btn-primary text-xs"
              disabled={not @device[:online]}
            >
              💧 Water Now
            </button>
          <% end %>

          <button
            phx-click="toggle_auto"
            phx-value-device_id={@device[:id]}
            phx-value-enabled={to_string(not auto_mode?(@device))}
            class="btn btn-sm btn-outline text-xs border-zinc-700 hover:bg-zinc-800"
            disabled={not @device[:online]}
          >
            {if auto_mode?(@device), do: "Disable Auto", else: "Enable Auto"}
          </button>
        </div>
      </div>
      
    <!-- Footer destructive -->
      <div class="px-4 py-2 bg-zinc-950 border-t border-zinc-800 flex gap-1 text-[10px]">
        <button
          phx-click="simulate_low_battery"
          phx-value-device_id={@device[:id]}
          class="flex-1 py-1 rounded bg-amber-900/40 hover:bg-amber-900/70 text-amber-300 transition"
          disabled={not @device[:online]}
        >
          Simulate Low Battery
        </button>

        <button
          phx-click="probe_device"
          phx-value-device_id={@device[:id]}
          class="px-2 py-1 rounded bg-sky-900/40 hover:bg-sky-900/70 text-sky-300 transition font-mono"
          disabled={@probing or not @device[:online]}
          title="Measure hybrid roundtrip latency (no side effects)"
        >
          ⏱
        </button>

        <button
          phx-click="kill_node"
          phx-value-device_id={@device[:id]}
          class="flex-1 py-1 rounded bg-red-900/40 hover:bg-red-900/70 text-red-300 transition"
          disabled={not @device[:online]}
        >
          Kill Node
        </button>
      </div>
    </div>
    """
  end

  # --- Helpers (pure, no side effects) ---

  defp get_metric(device, key) do
    get_in(device, [:metrics, key]) || get_in(device, [key]) || 0.0
  end

  defp valve_open?(device) do
    get_in(device, [:status, :valve_open]) || false
  end

  defp auto_mode?(device) do
    case get_in(device, [:status, :auto_mode]) do
      nil -> true
      v -> !!v
    end
  end

  defp gauge_width(val, min \\ 0, max \\ 100) do
    v = clamp(val, min, max)
    round((v - min) / (max - min) * 100)
  end

  defp clamp(v, min, max) when is_number(v), do: max(min, min(v, max))
  defp clamp(_, min, _), do: min

  defp format_pct(v) when is_number(v), do: "#{Float.round(v, 1)}%"
  defp format_pct(_), do: "—%"

  defp format_temp(v) when is_number(v), do: "#{Float.round(v, 1)}°C"
  defp format_temp(_), do: "—°C"

  defp format_last_seen(nil), do: "—"

  defp format_last_seen(ts) when is_integer(ts) do
    age = max(0, System.system_time(:millisecond) - ts)

    cond do
      age < 5_000 -> "now"
      age < 60_000 -> "#{div(age, 1000)}s"
      true -> "#{div(age, 60_000)}m"
    end
  end

  defp format_last_seen(_), do: "—"

  defp battery_color_class(v) when is_number(v) and v < 15, do: "bg-red-500"
  defp battery_color_class(v) when is_number(v) and v < 35, do: "bg-amber-400"
  defp battery_color_class(_), do: "bg-emerald-400"
end
