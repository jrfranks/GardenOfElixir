#ifndef PLANT_PHYSICS_H
#define PLANT_PHYSICS_H

#include <stdbool.h>
#include <stdint.h>

/*
 * C port of dashboard/lib/fleet_monitor/plant_physics.ex.
 *
 * Moisture / valve / battery rates match the Elixir engine exactly so a real
 * ESP32 node behaves like the Fleet Console simulators. Temperature noise uses
 * FNV-1a instead of :erlang.phash2 — that is intentional ESP32 "personality"
 * (noisier ADC), not a bug.
 */

double plant_update_moisture(double current, bool valve_open, double temp_c,
                             double dt_seconds);

double plant_daily_temperature_cycle(double hour_float, uint32_t device_seed);

double plant_humidity_for_temp(double temp_c, double water_boost);

double plant_update_battery(double current, bool valve_open, double dt_seconds,
                            uint32_t device_seed, int64_t time_seconds);

bool plant_auto_valve_state(bool current_valve, double moisture, double low,
                            double high);

bool plant_initial_valve_state(double moisture, double low, double high);

double plant_round1(double x);

uint32_t plant_device_seed(const char *device_id);

double plant_seeded_noise(uint32_t seed, int32_t tick, double amplitude);

#endif /* PLANT_PHYSICS_H */
