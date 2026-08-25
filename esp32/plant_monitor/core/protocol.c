#include "protocol.h"

#include <stdio.h>
#include <string.h>

static int sncat(char *out, size_t n, const char *fmt, const char *a,
                 const char *b) {
  int w = snprintf(out, n, fmt, a, b);
  if (w < 0 || (size_t)w >= n) {
    if (n > 0) {
      out[n - 1] = '\0';
    }
    return (int)n - 1;
  }
  return w;
}

void protocol_dt_topic(char *out, size_t n, const char *device_id,
                       const char *metric) {
  sncat(out, n, "v1/dt/fleet/plant/%s/%s", device_id, metric);
}

void protocol_status_topic(char *out, size_t n, const char *device_id) {
  snprintf(out, n, "v1/status/fleet/plant/%s", device_id);
}

void protocol_cmd_filter(char *out, size_t n, const char *device_id) {
  snprintf(out, n, "v1/cmd/fleet/plant/%s/#", device_id);
}

const char *protocol_action_from_topic(const char *topic, const char *device_id) {
  char prefix[128];
  int w = snprintf(prefix, sizeof(prefix), "v1/cmd/fleet/plant/%s/", device_id);
  if (w < 0 || (size_t)w >= sizeof(prefix)) {
    return NULL;
  }
  size_t plen = (size_t)w;
  if (strncmp(topic, prefix, plen) != 0) {
    return NULL;
  }
  const char *action = topic + plen;
  return action[0] ? action : NULL;
}

int protocol_encode_metric(char *out, size_t n, double value, const char *unit,
                           int64_t ts_ms) {
  return snprintf(out, n, "{\"value\":%.1f,\"unit\":\"%s\",\"ts\":%lld}", value,
                  unit, (long long)ts_ms);
}

int protocol_encode_sensors(char *out, size_t n, const plant_state_t *s) {
  return snprintf(out, n,
                  "{\"soil_moisture\":%.1f,\"temperature\":%.1f,"
                  "\"humidity\":%.1f,\"battery\":%.1f}",
                  s->soil_moisture, s->temperature, s->humidity, s->battery);
}

int protocol_encode_status(char *out, size_t n, const plant_state_t *s,
                           const char *iso8601, int online) {
  return snprintf(
      out, n,
      "{\"state\":\"%s\",\"type\":\"esp32\",\"fw\":\"%s\",\"last_seen\":\"%s\","
      "\"valve_open\":%s,\"auto_mode\":%s,\"moisture_low\":%.1f,"
      "\"moisture_high\":%.1f,\"soil_moisture\":%.1f,\"temperature\":%.1f,"
      "\"humidity\":%.1f,\"battery\":%.1f,\"report_interval_closed_ms\":%d,"
      "\"water_to_target\":%s}",
      online ? "online" : "offline", PROTO_FW_VERSION, iso8601,
      s->valve_open ? "true" : "false", s->auto_mode ? "true" : "false",
      s->moisture_low, s->moisture_high, s->soil_moisture, s->temperature,
      s->humidity, s->battery, s->report_interval_closed_ms,
      s->water_to_target ? "true" : "false");
}

int protocol_encode_lwt(char *out, size_t n) {
  return snprintf(out, n,
                  "{\"state\":\"offline\",\"reason\":\"disconnected\","
                  "\"type\":\"esp32\"}");
}
