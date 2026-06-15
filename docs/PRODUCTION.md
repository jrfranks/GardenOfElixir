# Production Hardening Guide

This document describes what must change before deploying **elixir-iot-fleet-monitor** beyond a local demo. The codebase intentionally uses production *patterns* (supervision, reconnection, structured logging) but **not** production security.

See also `DESIGN.md` §8 (Known Limitations) and `mosquitto/config/mosquitto.conf` (demo-only warnings).

---

## Mosquitto: Authentication & ACLs

**Current state (demo):** `allow_anonymous true` with no ACL file. Any client on the network can publish and subscribe to all `v1/#` topics.

**Production requirements:**

1. **Disable anonymous access**
   ```conf
   allow_anonymous false
   password_file /mosquitto/config/passwd
   acl_file /mosquitto/config/acl
   ```

2. **Per-device credentials** — Each Nerves/ESP32 node gets its own username/password. The Fleet Console bridge uses a dedicated `fleet_console` user with broader (but still scoped) rights.

3. **Topic ACLs** — Enforce read/write separation (matches `MqttBridge` schema):
   - Devices: write-only to `v1/dt/fleet/plant/{device_id}/#` (per-metric + aggregate `/sensors`)
   - Devices: write-only to `v1/status/fleet/plant/{device_id}` (retained status / LWT)
   - Devices: read-only on `v1/cmd/fleet/plant/{device_id}/#`
   - Console: read `v1/dt/fleet/plant/#` and `v1/status/fleet/plant/#`; write `v1/cmd/fleet/plant/#`

4. **Rotate credentials** — Treat device passwords like API keys; support revocation without fleet-wide downtime.

---

## TLS / Encryption

**Current state:** Plain MQTT on port 1883 (localhost in dev; exposed in docker-compose for demo).

**Production requirements:**

1. Enable a TLS listener in `mosquitto.conf`:
   ```conf
   listener 8883
   protocol mqtt
   cafile /mosquitto/certs/ca.crt
   certfile /mosquitto/certs/server.crt
   keyfile /mosquitto/certs/server.key
   require_certificate false
   ```

2. Pin CA certificates on devices (Nerves `emqtt` / ESP-IDF `esp_mqtt`).

3. Terminate HTTPS for the Phoenix endpoint (`Plug.SSL`, valid certs, `force_ssl` in `config/prod.exs`).

4. Do **not** expose unauthenticated MQTT or the LiveView console to the public internet.

---

## Secrets Management

| Secret | Demo | Production |
|--------|------|------------|
| `SECRET_KEY_BASE` | Generated or hardcoded in scripts | Required env var; rotate on compromise |
| `MQTT_USERNAME` / `MQTT_PASSWORD` | Empty (anonymous) | Per-environment credentials via vault/K8s secrets |
| Device passwords | N/A | Provisioned at manufacture or first-boot enrollment |

**Runtime config:** `dashboard/config/runtime.exs` already reads `MQTT_HOST`, `MQTT_PORT`, `MQTT_USERNAME`, and `MQTT_PASSWORD` from the environment (12-factor). Use the same pattern for all secrets — never commit them.

---

## Demo-Only Warnings (do not ship as-is)

The following are **intentionally open** for `make demo` and must be hardened:

- **`mosquitto/config/mosquitto.conf`** — `allow_anonymous true` (see file header comment)
- **LiveView command surface** — No authentication; device IDs guarded by allow-list only (see `FleetConsoleLive` and `DESIGN.md`)
- **`scripts/start-demo.sh`** — May generate an insecure `SECRET_KEY_BASE` if unset
- **Docker Compose** — Publishes Mosquitto `:1883` to the host without TLS

---

## Operational Checklist

- [ ] Mosquitto: auth + ACLs + TLS
- [ ] Phoenix: HTTPS, strong `SECRET_KEY_BASE`, network isolation
- [ ] MQTT bridge: credentials from secrets manager, reconnect backoff verified under broker restart
- [ ] Monitoring: broker health, bridge `health()`, device LWT/offline rates
- [ ] Backups: if persistence is added (Phase 4+), document retention and restore
- [ ] Rate limits / command authorization on the console API

---

## References

- `DESIGN.md` — Architecture, hybrid MQTT + BEAM model, known limitations
- `docs/PHASE1_ARCHITECTURE_AND_PLAN.md` — Original communication model and risk register
- `mosquitto/config/mosquitto.conf` — Inline security warnings for the demo broker