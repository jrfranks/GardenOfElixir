#include "plant_physics.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int g_fail = 0;

static void expect(int cond, const char *msg) {
  if (!cond) {
    fprintf(stderr, "FAIL: %s\n", msg);
    g_fail++;
  }
}

int main(void) {
  /* Rates copied from Elixir PlantPhysics tests. */
  double m1 = plant_update_moisture(50.0, false, 22.0, 10);
  expect(m1 < 50.0 && m1 >= 0.0, "decays when valve closed");
  expect(fabs(m1 - 49.8) < 1e-9, "idle rate -0.02%/s * 10s");

  double m = plant_update_moisture(95.0, true, 18.0, 20);
  expect(fabs(m - 97.0) < 1e-9, "watering +0.1%/s * 20s => 97");

  double cool = plant_update_moisture(60.0, false, 10.0, 30);
  double hot = plant_update_moisture(60.0, false, 35.0, 30);
  expect(fabs(cool - hot) < 1e-9, "temp unused (parity with Elixir)");

  double acc = 40.0;
  int i;
  for (i = 0; i < 20; i++) {
    acc = plant_update_moisture(acc, true, 20.0, 0.15);
  }
  expect(fabs(acc - 40.3) < 0.05, "small-dt accumulation");

  expect(plant_auto_valve_state(false, 12.0, 15.0, 45.0) == true, "open below low");
  expect(plant_auto_valve_state(true, 80.0, 15.0, 45.0) == false, "close above high");
  expect(plant_auto_valve_state(true, 30.0, 15.0, 45.0) == true, "hysteresis hold on");
  expect(plant_auto_valve_state(false, 30.0, 15.0, 45.0) == false,
         "hysteresis hold off");

  expect(plant_initial_valve_state(10.0, 18.0, 52.0) == true, "init open");
  expect(plant_initial_valve_state(80.0, 18.0, 52.0) == false, "init closed high");
  expect(plant_initial_valve_state(30.0, 18.0, 52.0) == false, "init closed in-band");

  double b0 = 80.0;
  double idle = plant_update_battery(b0, false, 3600, 1, 0);
  double active = plant_update_battery(b0, true, 3600, 1, 0);
  expect(idle < b0, "battery drains idle");
  expect(active < idle, "battery drains faster with valve");

  uint32_t seed = plant_device_seed("esp32-fw-001");
  expect(seed != plant_device_seed("esp32-fw-002"), "seeds differ per device");
  double t1 = plant_daily_temperature_cycle(14.0, seed);
  double t2 = plant_daily_temperature_cycle(14.0, seed);
  expect(t1 == t2, "temperature is deterministic");
  expect(t1 > 5.0 && t1 < 40.0, "temperature in plausible range");

  if (g_fail) {
    fprintf(stderr, "%d physics tests failed\n", g_fail);
    return 1;
  }
  printf("test_physics: ok\n");
  return 0;
}
