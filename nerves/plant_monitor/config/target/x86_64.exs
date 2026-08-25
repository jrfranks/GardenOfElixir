import Config

# QEMU x86_64: MQTT broker is usually the host. Set MQTT_HOST at runtime
# (erlinit env or `fwup` overlay). Default in runtime.exs is 127.0.0.1, which
# is the guest — override to the host IP / gateway.
