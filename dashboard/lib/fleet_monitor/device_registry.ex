defmodule FleetMonitor.DeviceRegistry do
  @moduledoc """
  Thin wrapper around Elixir Registry for named device simulators.
  Also can be extended with :pg for distributed cluster members (Phase 3+).
  Started in application supervision tree.
  """

  @doc """
  Returns the child spec for the underlying Registry.
  In application.ex we use the explicit {Registry, ...} form for boot reliability
  (the bare-module child_spec return form had supervisor validation issues in some runs).
  The module still encapsulates the lookup API per design §5.
  """
  def child_spec(_opts) do
    {Registry, keys: :unique, name: __MODULE__, partitions: System.schedulers_online()}
  end

  def lookup(device_id) do
    Registry.lookup(__MODULE__, device_id)
  end

  def all_devices do
    Registry.select(__MODULE__, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
