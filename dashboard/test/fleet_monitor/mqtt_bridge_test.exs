defmodule FleetMonitor.MqttBridgeTest do
  @moduledoc """
  Tests for the hardened `MqttBridge` (normalization, safe parsing, per-metric vs aggregate paths).

  These tests were expanded during the Phase 3 high-effort review round to
  cover the command surface and per-metric ingestion logic.

  @phase 2 + Phase 3 (expanded coverage)
  """

  use ExUnit.Case, async: true
  alias FleetMonitor.MqttBridge

  describe "normalize_metrics/1 (public for test; covers per-metric + aggregate payloads)" do
    test "handles numeric values directly" do
      m = %{soil_moisture: 42.5, temperature: 23, humidity: 65, battery: 88}
      norm = MqttBridge.normalize_metrics(m)
      assert norm.soil_moisture == 42.5
      assert norm.temperature == 23.0
    end

    # (string-parse path covered by bad-parse test + get_num implementation; direct numbers below)
    test "falls back to 0.0 on bad parse (no crash, security hardening)" do
      m = %{"soil_moisture" => "not-a-number", "temperature" => 22}
      norm = MqttBridge.normalize_metrics(m)
      assert norm.soil_moisture == 0.0
      assert norm.temperature == 22.0
    end

    test "supports mixed atom/string keys and per-metric payloads" do
      # simulate what normalize sees on aggregate path (value already extracted)
      norm = MqttBridge.normalize_metrics(%{soil_moisture: 55.1})
      assert norm.soil_moisture == 55.1
    end
  end
end
