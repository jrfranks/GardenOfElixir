#include "plant_runtime.h"

#include "json_util.h"
#include "plant_physics.h"

#include <string.h>

static double clampd(double v, double lo, double hi) {
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return v;
}

static int duration_ms_from_payload(const char *json) {
  /* Mirror Elixir get_duration/1: missing key => 5000; 0 => water-to-target. */
  if (!json || !json_has_key(json, "duration_ms")) {
    return 5000;
  }
  int d = json_get_int(json, "duration_ms", 5000);
  if (d == 0) {
    return 0;
  }
  if (d < 0) {
    return 5000;
  }
  if (d > 30000) {
    return 30000;
  }
  return d;
}

void plant_runtime_factory_reset(plant_state_t *s, int64_t now_ms) {
  (void)now_ms;
  s->soil_moisture = 41.0;
  s->temperature = 23.5;
  s->humidity = 61.0;
  s->battery = 84.0;
  s->auto_mode = true;
  s->moisture_low = 17.0;
  s->moisture_high = 55.0;
  s->water_pulse_until_ms = 0;
  s->water_to_target = false;
  s->last_telemetry_ms = 0;
  s->report_interval_closed_ms = 60000;
  s->valve_open =
      plant_initial_valve_state(s->soil_moisture, s->moisture_low, s->moisture_high);
}

void plant_runtime_init(plant_state_t *s, const char *device_id, int64_t now_ms) {
  memset(s, 0, sizeof(*s));
  if (!device_id || !device_id[0]) {
    device_id = "esp32-fw-001";
  }
  strncpy(s->device_id, device_id, PLANT_DEVICE_ID_MAX - 1);
  s->seed = plant_device_seed(s->device_id);
  /* Spread initial moisture using the seed so two flashed boards differ. */
  s->soil_moisture = 41.0 + (double)(s->seed % 1200) / 100.0;
  if (s->soil_moisture > 53.0) {
    s->soil_moisture = 53.0;
  }
  plant_runtime_factory_reset(s, now_ms);
  /* factory_reset overwrites moisture; restore the seeded value. */
  s->soil_moisture = 41.0 + (double)(s->seed % 1200) / 100.0;
  if (s->soil_moisture > 53.0) {
    s->soil_moisture = 53.0;
  }
  s->valve_open =
      plant_initial_valve_state(s->soil_moisture, s->moisture_low, s->moisture_high);
  s->last_telemetry_ms = 0; /* force a birth telemetry on first tick */
}

int plant_runtime_tick(plant_state_t *s, double dt_seconds, int64_t now_ms,
                       int64_t sim_time_ms) {
  if (dt_seconds < 0.01) {
    dt_seconds = 0.01;
  }

  double hour = (double)now_ms / 3600000.0 + 0.5; /* ESP32 phase offset */
  double temp = plant_daily_temperature_cycle(hour, s->seed);
  double moisture =
      plant_update_moisture(s->soil_moisture, s->valve_open, temp, dt_seconds);
  double water_boost = s->valve_open ? 11.0 : 0.0;
  double humidity = plant_humidity_for_temp(temp, water_boost);
  double battery = plant_update_battery(s->battery, s->valve_open, dt_seconds,
                                        s->seed, now_ms / 1000);

  bool pulse_active =
      s->water_pulse_until_ms != 0 && s->water_pulse_until_ms > now_ms;

  bool valve;
  if (s->water_to_target) {
    valve = moisture < s->moisture_high;
  } else if (pulse_active) {
    valve = true;
  } else if (s->auto_mode) {
    valve = plant_auto_valve_state(s->valve_open, moisture, s->moisture_low,
                                   s->moisture_high);
  } else {
    valve = s->valve_open;
  }

  if (s->water_to_target && !valve) {
    s->water_to_target = false;
  }
  if (!pulse_active) {
    s->water_pulse_until_ms = 0;
  }

  int flags = 0;
  if (valve != s->valve_open) {
    flags |= PLANT_PUBLISH_STATUS;
  }

  s->soil_moisture = moisture;
  s->temperature = temp;
  s->humidity = humidity;
  s->battery = battery;
  s->valve_open = valve;

  bool watering = valve || s->water_to_target ||
                  (s->water_pulse_until_ms != 0 && s->water_pulse_until_ms > now_ms);
  int desired = watering ? 15000 : s->report_interval_closed_ms;
  if (s->last_telemetry_ms == 0 ||
      sim_time_ms - s->last_telemetry_ms >= desired) {
    s->last_telemetry_ms = sim_time_ms;
    flags |= PLANT_PUBLISH_TELEMETRY | PLANT_PUBLISH_STATUS;
  }
  return flags;
}

int plant_runtime_apply_command(plant_state_t *s, const char *action,
                                const char *json, int64_t now_ms) {
  if (!action) {
    return 0;
  }
  if (!json) {
    json = "{}";
  }

  if (strcmp(action, "water_now") == 0) {
    int duration = duration_ms_from_payload(json);
    if (duration == 0) {
      s->valve_open = true;
      s->water_to_target = true;
      s->water_pulse_until_ms = 0;
    } else {
      s->valve_open = true;
      s->water_to_target = false;
      s->water_pulse_until_ms = now_ms + duration;
    }
  } else if (strcmp(action, "set_auto_mode") == 0) {
    int enabled = json_get_bool(json, "enabled", 1);
    bool pulse_active =
        s->water_pulse_until_ms != 0 && s->water_pulse_until_ms > now_ms;
    s->auto_mode = enabled != 0;
    if (s->auto_mode && !pulse_active) {
      s->valve_open = plant_initial_valve_state(
          s->soil_moisture, s->moisture_low, s->moisture_high);
    }
  } else if (strcmp(action, "set_moisture_thresholds") == 0) {
    const double min_gap = 3.0;
    double low = json_has_key(json, "low")
                     ? json_get_double(json, "low", s->moisture_low)
                     : s->moisture_low;
    double high = json_has_key(json, "high")
                      ? json_get_double(json, "high", s->moisture_high)
                      : s->moisture_high;
    low = clampd(low, 0.0, 99.0);
    high = clampd(high, low + min_gap, 100.0);
    high = high > 100.0 ? 100.0 : (high < low + min_gap ? low + min_gap : high);
    if (high > 100.0) {
      high = 100.0;
    }
    low = low < 0.0 ? 0.0 : (low > high - min_gap ? high - min_gap : low);
    s->moisture_low = low;
    s->moisture_high = high;
    bool pulse_active =
        s->water_pulse_until_ms != 0 && s->water_pulse_until_ms > now_ms;
    if (s->auto_mode && !pulse_active) {
      s->valve_open =
          plant_initial_valve_state(s->soil_moisture, low, high);
    }
  } else if (strcmp(action, "simulate_low_battery") == 0) {
    s->battery = 6.0;
  } else if (strcmp(action, "ping") == 0) {
    /* no physics change; caller still republishes telemetry */
  } else if (strcmp(action, "stop_water") == 0) {
    s->valve_open = false;
    s->water_pulse_until_ms = 0;
    s->water_to_target = false;
  } else if (strcmp(action, "set_telemetry_interval") == 0) {
    int interval = json_get_int(json, "interval_ms", 60000);
    if (interval < 5000) {
      interval = 5000;
    }
    if (interval > 600000) {
      interval = 600000;
    }
    s->report_interval_closed_ms = interval;
  } else if (strcmp(action, "factory_reset") == 0) {
    char id[PLANT_DEVICE_ID_MAX];
    strncpy(id, s->device_id, sizeof(id) - 1);
    id[sizeof(id) - 1] = '\0';
    uint32_t seed = s->seed;
    plant_runtime_init(s, id, now_ms);
    s->seed = seed;
  } else if (strcmp(action, "reboot") == 0) {
    return -1; /* caller performs platform reboot */
  } else {
    return 0;
  }

  return PLANT_PUBLISH_TELEMETRY | PLANT_PUBLISH_STATUS;
}
