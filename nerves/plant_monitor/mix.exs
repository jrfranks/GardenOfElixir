defmodule PlantMonitor.MixProject do
  use Mix.Project

  @app :plant_monitor
  @version "0.1.0"
  @all_targets [:x86_64]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      preferred_cli_target: [run: :host, test: :host]
    ] ++ nerves_project()
  end

  def application do
    [
      mod: {PlantMonitor.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      test: ["test"]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      # Tortoise is the usual Nerves MQTT client (pure Elixir, no quicer NIF).
      {:tortoise311, "~> 0.12"},
      {:libcluster, "~> 3.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ] ++ nerves_deps()
  end

  # Host `mix test` / `mix run` must work without nerves_bootstrap or a system image.
  defp nerves_deps do
    if Mix.target() == :host do
      []
    else
      [
        {:nerves, "~> 1.14", runtime: false},
        {:shoehorn, "~> 0.9"},
        {:ring_logger, "~> 0.11"},
        {:toolshed, "~> 0.4"},
        {:nerves_runtime, "~> 0.13"},
        {:nerves_pack, "~> 0.7"},
        {:nerves_system_x86_64, "~> 1.33", runtime: false, targets: @all_targets}
      ]
    end
  end

  defp nerves_project do
    if Mix.target() == :host do
      []
    else
      [
        archives: [nerves_bootstrap: "~> 1.13"],
        releases: [{@app, release()}],
        preferred_cli_target: [run: :host, test: :host]
      ]
    end
  end

  defp release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end
end
