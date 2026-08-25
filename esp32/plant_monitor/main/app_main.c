#include "app_config.h"
#include "mqtt_app.h"
#include "plant_runtime.h"
#include "plant_task.h"
#include "wifi.h"

#include "esp_log.h"
#include "esp_timer.h"

static const char *TAG = "app";

void app_main(void) {
  /* Static: MQTT last-will and the plant task both keep this pointer. */
  static plant_state_t state;
  plant_runtime_init(&state, CONFIG_PLANT_DEVICE_ID, esp_timer_get_time() / 1000);
  ESP_LOGI(TAG, "plant monitor %s fw=%s", state.device_id, "0.1.0");

  ESP_ERROR_CHECK(plant_wifi_start());
  ESP_ERROR_CHECK(plant_task_start(&state));
  ESP_ERROR_CHECK(plant_mqtt_start(&state));
}
