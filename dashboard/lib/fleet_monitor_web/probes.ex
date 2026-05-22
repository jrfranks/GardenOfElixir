defmodule FleetMonitorWeb.Probes do
  @moduledoc """
  Extracted probe state machine for the hybrid roundtrip latency feature.

  Previously this logic (and its 47-line initiate_probe plus supporting functions)
  lived inside FleetConsoleLive, contributing to the main orchestrator's
  complexity (728 LOC hotspot after the Phase 3 probe improvements).

  This small focused module owns:
    - path detection (:direct via local Registry/PubSub vs :mqtt via bridge)
    - probe initiation with prior-timer cancellation + delete hygiene (prevents
      late telemetry from abandoned probes being mis-attributed)
    - timeout scheduling + defensive clear
    - completion on authoritative telemetry (monotonic delta, stores {ms, path})
    - conditional flash + global "last probe" clearing only for the "Probe Random" UX

  Invariants preserved exactly (no observable behavior change for `make demo`):
    - Probe state (pending_probes, roundtrips, roundtrip_ms) remains LiveView-local assigns.
    - Never touches FleetState, DeviceManager children, or simulator internals except
      the intentional zero-side-effect Commands.ping.
    - Timer hygiene + exact-match pending check prevents races on rapid re-probe or kill.
    - Per-card probes (flash: false) do not *clear* the global Cluster Health "Last probe"
      value on initiation (unlike "Probe Random"); any probe completion updates
      `@roundtrip_ms` via the telemetry reconciliation path (pre-existing semantics).
    - "Telemetry is the source of truth": measurement only recorded on real telemetry arrival.
    - Binary device IDs, guarded surface (callers still enforce known_device?).
    - Hybrid labeling and ~1.8s timeout semantics identical.

  Coupling notes (required for 1-line LV delegation + exact behavior preservation):
    - `initiate_probe/3` and `maybe_complete_probe/3` operate on a LiveView `socket`
      and use `assign/3` + `LiveView.put_flash/3`. They must be called from the
      owning LiveView process (so `self()` resolves correctly for `Process.send_after`
      targeting the LV's `handle_info`).
    - `handle_probe_timeout/3` and `detect_probe_path/1` are map-only or pure.
    - A more "pure" tuple-returning API was considered but rejected to keep
      delegation sites 1-line and preserve 100% original control flow / side effects.

  The main FleetConsoleLive now delegates the probe surfaces and the telemetry
  completion path. All handle_event / handle_info for probes remain thin wrappers.

  See DESIGN.md "Command & Control Flow" and the probe description in
  FleetConsoleLive for the educational intent of the hybrid measurement.

  @phase 3
  """

  # assign comes from Phoenix.Component (re-exported for use Phoenix.LiveView + components).
  # put_flash is delegated via Phoenix.LiveView.
  import Phoenix.Component, only: [assign: 3]

  alias FleetMonitor.{Commands, DeviceManager}
  alias Phoenix.LiveView, as: LiveView

  @probe_timeout_ms 1800

  @doc """
  Determines the ingress path label for demo/educational purposes.

  - :direct when the device process is locally registered (Nerves sim on same node)
  - :mqtt otherwise (future remote nodes or ESP32 path)

  NOTE: the label only describes command delivery leg; the measured roundtrip
  always traverses the MQTT bridge for wire-visible confirmation.
  """
  def detect_probe_path(device_id) when is_binary(device_id) do
    case DeviceManager.lookup_pid(device_id) do
      pid when is_pid(pid) -> :direct
      _ -> :mqtt
    end
  end

  def detect_probe_path(_), do: :mqtt

  # Private: the core defensive hygiene for re-probe (cancel + explicit delete).
  # Extracted here so the pattern is obvious and the public initiate_probe stays
  # focused on the end-to-end flow while preserving every original comment.
  defp cancel_prior_probe(pending, device_id) do
    case Map.get(pending, device_id) do
      {_, _, old_ref} ->
        Process.cancel_timer(old_ref)
        Map.delete(pending, device_id)

      _ ->
        pending
    end
  end

  @doc """
  Initiates a side-effect-free ping probe for the given device.

  Records t0 + path + timer ref in pending_probes.
  On re-probe of same device, cancels prior timer and drops the old entry
  so a late confirmation cannot steal attribution from a newer probe.

  **Must be called from within the LiveView process** (handle_event / handle_info
  context) so that `self()` resolves to the LV pid for the scheduled
  `{:probe_timeout, ...}` message and `Process.cancel_timer` targets the correct ref.
  `Commands.ping` and timer side-effects execute in the caller's context.

  Returns the updated socket (delegation target from FleetConsoleLive).
  """
  def initiate_probe(device_id, socket, opts) do
    flash? = Keyword.get(opts, :flash, false)
    at = System.monotonic_time(:millisecond)
    path = detect_probe_path(device_id)

    pending = Map.get(socket.assigns, :pending_probes, %{})

    # Cancel any prior + explicitly drop the old pending entry (so late telemetry
    # from an abandoned earlier probe cannot hit maybe_complete_probe and get
    # attributed against the newer t0/path stored under the same device_id).
    pending = cancel_prior_probe(pending, device_id)

    # captured (ignored for now); fire-and-forget accepted in demo (bridge is up)
    _ping_res = Commands.ping(device_id)

    timer_ref = Process.send_after(self(), {:probe_timeout, device_id, at}, @probe_timeout_ms)
    new_pending = Map.put(pending, device_id, {at, path, timer_ref})

    # Apply pending update, then (only for global "Probe Random") the roundtrip clear + flash.
    # Per-card probes leave the Cluster Health "Last probe" untouched on initiation.
    # Uses then/2 for concise single-expression control flow (addresses prior rebinding nit).
    socket
    |> assign(:pending_probes, new_pending)
    |> then(fn s ->
      if flash? do
        s
        |> assign(:roundtrip_ms, nil)
        |> LiveView.put_flash(:info, "Probe sent to #{device_id} (#{path})...")
      else
        s
      end
    end)
  end

  @doc """
  Called from telemetry handler when a device reports.

  If a probe was pending for this device, compute the end-to-end delta using
  monotonic time and store the result (with path badge) for the DeviceCard footer.
  Also updates the global Cluster Health "Last probe" value (for *any* completing
  probe; the flash? distinction only gates clearing on *initiation* of global probes).

  Combined with the prior-cancel in initiate_probe, this guarantees correct
  attribution even under rapid clicks or mixed probe kinds.
  """
  def maybe_complete_probe(socket, device_id, now_mono) do
    pending = Map.get(socket.assigns, :pending_probes, %{})
    roundtrips = Map.get(socket.assigns, :roundtrips, %{})

    case Map.get(pending, device_id) do
      {t0, path, _ref} ->
        delta = now_mono - t0

        result = %{
          ms: delta,
          path: path
          # measured_at omitted (unused in rendering / health panel; reduces overhead)
        }

        new_roundtrips = Map.put(roundtrips, device_id, result)
        new_pending = Map.delete(pending, device_id)

        socket
        |> assign(:pending_probes, new_pending)
        |> assign(:roundtrips, new_roundtrips)
        |> assign(:roundtrip_ms, delta)

      _ ->
        socket
    end
  end

  @doc """
  Defensive timeout handler (called via handle_info from scheduled timer).

  Only clears the exact pending entry that matches the sent_at we scheduled.
  Late or stale timers (from cancelled probes) are ignored.
  """
  @spec handle_probe_timeout(map, binary, integer) :: map
  def handle_probe_timeout(pending_probes, device_id, sent_at) when is_map(pending_probes) do
    case Map.get(pending_probes, device_id) do
      {^sent_at, _path, _ref} ->
        # still pending this exact probe → clear it (no result stored; rare for local sims)
        Map.delete(pending_probes, device_id)

      _ ->
        pending_probes
    end
  end

  def handle_probe_timeout(pending_probes, _device_id, _sent_at), do: pending_probes
end
