#include "plant_physics.h"

#include <math.h>
#include <string.h>

double plant_round1(double x) { return round(x * 10.0) / 10.0; }

uint32_t plant_device_seed(const char *device_id) {
  /* FNV-1a 32-bit. Elixir simulators use :erlang.phash2; we deliberately
   * differ so a real ESP32 has its own micro-climate (see plant_physics.h). */
  uint32_t h = 2166136261u;
  if (!device_id) {
    return h;
  }
  for (const unsigned char *p = (const unsigned char *)device_id; *p; p++) {
    h ^= *p;
    h *= 16777619u;
  }
  /* Match Esp32Plant's seed mix: phash2(device_id <> "esp32"). */
  const char *suffix = "esp32";
  for (const unsigned char *p = (const unsigned char *)suffix; *p; p++) {
    h ^= *p;
    h *= 16777619u;
  }
  return h;
}

double plant_seeded_noise(uint32_t seed, int32_t tick, double amplitude) {
  uint32_t h = 2166136261u ^ seed;
  h ^= (uint32_t)tick;
  h *= 16777619u;
  h ^= (uint32_t)((uint32_t)tick >> 8);
  h *= 16777619u;
  double x = (double)(h % 1000000u) / 500000.0 - 1.0;
  return (sin(x * 5.3) * 0.6 + sin(x * 11.7 + (double)tick * 0.09) * 0.4) *
         amplitude;
}

double plant_update_moisture(double current, bool valve_open, double temp_c,
                             double dt_seconds) {
  (void)temp_c; /* unused in Elixir too; kept for call-site parity */
  if (dt_seconds < 0.0) {
    dt_seconds = 0.0;
  }
  if (valve_open) {
    double next = current + 0.1 * dt_seconds;
    return next > 100.0 ? 100.0 : next;
  }
  double next = current - 0.02 * dt_seconds;
  return next < 0.0 ? 0.0 : next;
}

double plant_daily_temperature_cycle(double hour_float, uint32_t device_seed) {
  double h = fmod(hour_float, 24.0);
  if (h < 0.0) {
    h += 24.0;
  }
  double rad = (h - 14.5) * 2.0 * 3.14159265358979323846 / 24.0;
  double daily = 19.5 + 10.8 * sin(rad);
  double drift = plant_seeded_noise(device_seed, (int32_t)(hour_float * 4.0), 1.8);
  double fast = plant_seeded_noise(device_seed, (int32_t)(hour_float * 120.0), 0.35);
  return plant_round1(daily + drift + fast);
}

double plant_humidity_for_temp(double temp_c, double water_boost) {
  double base = 68.0 - (temp_c - 16.0) * 1.65;
  double boosted = base + water_boost;
  double variation = sin(temp_c * 0.7) * 2.2;
  double h = boosted + variation;
  if (h < 28.0) {
    h = 28.0;
  }
  if (h > 94.0) {
    h = 94.0;
  }
  return plant_round1(h);
}

double plant_update_battery(double current, bool valve_open, double dt_seconds,
                            uint32_t device_seed, int64_t time_seconds) {
  if (dt_seconds < 0.0) {
    dt_seconds = 0.0;
  }
  double base = 0.00078 * dt_seconds;
  double pump = valve_open ? 0.0058 * dt_seconds : 0.0;
  double jitter =
      plant_seeded_noise(device_seed, (int32_t)time_seconds, 0.00015) * dt_seconds;
  double next = current - base - pump - jitter;
  if (next < 0.0) {
    next = 0.0;
  }
  return plant_round1(next);
}

bool plant_auto_valve_state(bool current_valve, double moisture, double low,
                            double high) {
  if (moisture <= low) {
    return true;
  }
  if (moisture >= high) {
    return false;
  }
  return current_valve;
}

bool plant_initial_valve_state(double moisture, double low, double high) {
  if (moisture <= low) {
    return true;
  }
  if (moisture >= high) {
    return false;
  }
  return false;
}
