#ifndef PLANT_RUNTIME_H
#define PLANT_RUNTIME_H

#include <stdbool.h>
#include <stdint.h>

#define PLANT_DEVICE_ID_MAX 48
#define PLANT_PUBLISH_TELEMETRY 1
#define PLANT_PUBLISH_STATUS 2

typedef struct {
  char device_id[PLANT_DEVICE_ID_MAX];
  uint32_t seed;
  double soil_moisture;
  double temperature;
  double humidity;
  double battery;
  bool valve_open;
  bool auto_mode;
  double moisture_low;
  double moisture_high;
  int64_t water_pulse_until_ms;
  bool water_to_target;
  int64_t last_telemetry_ms;
  int report_interval_closed_ms;
} plant_state_t;

void plant_runtime_init(plant_state_t *s, const char *device_id, int64_t now_ms);

/* Advance physics. `sim_time_ms` is monotonic demo time (like SimulationTimer).
 * Returns a bitmask of PLANT_PUBLISH_* if the caller should emit MQTT. */
int plant_runtime_tick(plant_state_t *s, double dt_seconds, int64_t now_ms,
                       int64_t sim_time_ms);

/* Apply a console command (`water_now`, `ping`, ...). Returns publish flags. */
int plant_runtime_apply_command(plant_state_t *s, const char *action,
                                const char *json, int64_t now_ms);

void plant_runtime_factory_reset(plant_state_t *s, int64_t now_ms);

#endif /* PLANT_RUNTIME_H */
