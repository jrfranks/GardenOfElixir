#ifndef PLANT_TASK_H
#define PLANT_TASK_H

#include "esp_err.h"
#include "plant_runtime.h"

esp_err_t plant_task_start(plant_state_t *state);
void plant_task_enqueue_command(const char *action, const char *json);
void plant_task_force_publish(void);

#endif
