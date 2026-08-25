#ifndef MQTT_APP_H
#define MQTT_APP_H

#include "plant_runtime.h"

#include "esp_err.h"
#include <stdbool.h>

esp_err_t plant_mqtt_start(plant_state_t *state);
void plant_mqtt_publish(const char *topic, const char *payload, int qos,
                        bool retain);
bool plant_mqtt_is_connected(void);

#endif
