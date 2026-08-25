#include "json_util.h"
#include "plant_runtime.h"
#include "protocol.h"

#include <stdio.h>
#include <string.h>

static int g_fail = 0;

static void expect(int cond, const char *msg) {
  if (!cond) {
    fprintf(stderr, "FAIL: %s\n", msg);
    g_fail++;
  }
}

int main(void) {
  expect(json_get_int("{\"duration_ms\":0}", "duration_ms", 5) == 0, "duration 0");
  expect(json_get_int("{\"duration_ms\":8000}", "duration_ms", 5) == 8000,
         "duration 8000");
  expect(json_get_bool("{\"enabled\":true}", "enabled", 0) == 1, "bool true");
  expect(json_get_bool("{\"enabled\":false}", "enabled", 1) == 0, "bool false");
  expect(json_get_double("{\"low\":18.5,\"high\":52}", "low", 0) == 18.5,
         "double low");
  expect(json_has_key("{}", "duration_ms") == 0, "missing key");

  plant_state_t s;
  plant_runtime_init(&s, "esp32-fw-001", 1000);
  expect(strcmp(s.device_id, "esp32-fw-001") == 0, "device id");
  expect(s.auto_mode == true, "auto on");
  expect(s.report_interval_closed_ms == 60000, "default interval");

  int flags = plant_runtime_apply_command(&s, "water_now", "{\"duration_ms\":0}",
                                         2000);
  expect(flags & PLANT_PUBLISH_TELEMETRY, "water_now publishes");
  expect(s.water_to_target == true && s.valve_open == true, "water to target");

  (void)plant_runtime_apply_command(&s, "stop_water", "{}", 3000);
  expect(s.valve_open == false && s.water_to_target == false, "stop_water");

  (void)plant_runtime_apply_command(&s, "water_now", "{\"duration_ms\":8000}",
                                   4000);
  expect(s.water_pulse_until_ms == 12000, "timed pulse");

  plant_runtime_apply_command(&s, "set_auto_mode", "{\"enabled\":false}", 5000);
  expect(s.auto_mode == false, "auto off");

  plant_runtime_apply_command(&s, "set_moisture_thresholds",
                             "{\"low\":20,\"high\":60}", 6000);
  expect(s.moisture_low == 20.0 && s.moisture_high == 60.0, "thresholds");

  plant_runtime_apply_command(&s, "simulate_low_battery", "{}", 7000);
  expect(s.battery == 6.0, "low battery");

  plant_runtime_apply_command(&s, "set_telemetry_interval",
                             "{\"interval_ms\":5000}", 8000);
  expect(s.report_interval_closed_ms == 5000, "interval");

  expect(plant_runtime_apply_command(&s, "reboot", "{}", 9000) == -1,
         "reboot sentinel");

  char topic[192], payload[768];
  protocol_dt_topic(topic, sizeof(topic), "esp32-fw-001", "sensors");
  expect(strcmp(topic, "v1/dt/fleet/plant/esp32-fw-001/sensors") == 0,
         "sensors topic");
  protocol_status_topic(topic, sizeof(topic), "esp32-fw-001");
  expect(strcmp(topic, "v1/status/fleet/plant/esp32-fw-001") == 0, "status topic");
  protocol_cmd_filter(topic, sizeof(topic), "esp32-fw-001");
  expect(strcmp(topic, "v1/cmd/fleet/plant/esp32-fw-001/#") == 0, "cmd filter");

  const char *act = protocol_action_from_topic(
      "v1/cmd/fleet/plant/esp32-fw-001/water_now", "esp32-fw-001");
  expect(act && strcmp(act, "water_now") == 0, "action from topic");

  protocol_encode_sensors(payload, sizeof(payload), &s);
  expect(strstr(payload, "soil_moisture") != NULL, "sensors json");
  protocol_encode_status(payload, sizeof(payload), &s, "2026-01-01T00:00:00Z", 1);
  expect(strstr(payload, "\"type\":\"esp32\"") != NULL, "status type");
  expect(strstr(payload, "\"state\":\"online\"") != NULL, "status online");

  /* Tick with watering should eventually request telemetry (last_telemetry=0). */
  plant_runtime_init(&s, "esp32-fw-009", 0);
  flags = plant_runtime_tick(&s, 0.2, 200, 200);
  expect(flags & PLANT_PUBLISH_TELEMETRY, "first tick publishes (birth)");

  if (g_fail) {
    fprintf(stderr, "%d runtime tests failed\n", g_fail);
    return 1;
  }
  printf("test_runtime: ok\n");
  return 0;
}
