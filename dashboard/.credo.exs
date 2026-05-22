%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "src/",
          "test/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/test/",
          "apps/*/web/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/priv/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        disabled: [
          # We intentionally attach rich Logger metadata (device, duration_ms, topic, etc.)
          # in the demo simulators and MqttBridge for observability. This check is
          # extremely noisy for demo/structured-logging projects, so we disable it.
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, false}
        ]
      }
    }
  ]
}
