import Config

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
config :nerves, source_date_epoch: "1700000000"

config :shoehorn,
  init: [:nerves_runtime, :nerves_pack],
  app: :plant_monitor

config :logger, backends: [RingLogger]

config :mdns_lite,
  hosts: [:hostname, "plant-monitor"],
  ttl: 120,
  services: [
    %{protocol: "ssh", transport: "tcp", port: 22}
  ]

# QEMU x86_64 typically has eth0. Wi-Fi targets can add wlan0 via vintage_net_wifi.
config :vintage_net,
  regulatory_domain: "US",
  config: [
    {"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}}
  ]

if File.exists?("config/target/#{Mix.target()}.exs") do
  import_config "target/#{Mix.target()}.exs"
end
