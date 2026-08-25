#include "plant_task.h"
#include "app_config.h"
#include "mqtt_app.h"
#include "protocol.h"

#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

static const char *TAG = "plant";

typedef struct {
  char action[48];
  char json[512];
} cmd_msg_t;

static plant_state_t *s_state;
static QueueHandle_t s_cmdq;
static volatile bool s_force_publish;

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static void iso8601(char *out, size_t n) {
  time_t t = time(NULL);
  struct tm tm;
  gmtime_r(&t, &tm);
  strftime(out, n, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

static void set_valve_gpio(bool open) {
  gpio_set_level(CONFIG_PLANT_VALVE_GPIO, open ? 1 : 0);
}

static void publish_telemetry(plant_state_t *s) {
  char topic[192], payload[512];
  int64_t ts = (int64_t)time(NULL) * 1000;

  protocol_dt_topic(topic, sizeof(topic), s->device_id, "sensors");
  protocol_encode_sensors(payload, sizeof(payload), s);
  plant_mqtt_publish(topic, payload, 0, false);

  protocol_dt_topic(topic, sizeof(topic), s->device_id, "soil_moisture");
  protocol_encode_metric(payload, sizeof(payload), s->soil_moisture, "%", ts);
  plant_mqtt_publish(topic, payload, 0, false);

  protocol_dt_topic(topic, sizeof(topic), s->device_id, "temperature");
  protocol_encode_metric(payload, sizeof(payload), s->temperature, "C", ts);
  plant_mqtt_publish(topic, payload, 0, false);

  protocol_dt_topic(topic, sizeof(topic), s->device_id, "humidity");
  protocol_encode_metric(payload, sizeof(payload), s->humidity, "%", ts);
  plant_mqtt_publish(topic, payload, 0, false);

  protocol_dt_topic(topic, sizeof(topic), s->device_id, "battery");
  protocol_encode_metric(payload, sizeof(payload), s->battery, "%", ts);
  plant_mqtt_publish(topic, payload, 0, false);
}

static void publish_status(plant_state_t *s, int online) {
  char topic[192], payload[768], iso[40];
  iso8601(iso, sizeof(iso));
  protocol_status_topic(topic, sizeof(topic), s->device_id);
  protocol_encode_status(payload, sizeof(payload), s, iso, online);
  plant_mqtt_publish(topic, payload, 1, true);
}

static void apply_flags(plant_state_t *s, int flags) {
  if (flags < 0) {
    ESP_LOGW(TAG, "reboot command — restarting");
    vTaskDelay(pdMS_TO_TICKS(200));
    esp_restart();
  }
  if (flags & PLANT_PUBLISH_TELEMETRY) {
    publish_telemetry(s);
  }
  if (flags & PLANT_PUBLISH_STATUS) {
    publish_status(s, 1);
  }
  set_valve_gpio(s->valve_open);
}

static void plant_loop(void *arg) {
  (void)arg;
  int64_t last = now_ms();
  int64_t sim = 0;
  const int tick_ms = CONFIG_PLANT_TICK_MS;

  while (1) {
    cmd_msg_t msg;
    if (xQueueReceive(s_cmdq, &msg, pdMS_TO_TICKS(tick_ms)) == pdTRUE) {
      int flags = plant_runtime_apply_command(s_state, msg.action, msg.json,
                                              now_ms());
      apply_flags(s_state, flags);
    }

    int64_t now = now_ms();
    if (now - last >= tick_ms) {
      double dt = (double)(now - last) / 1000.0;
      sim += now - last;
      int flags = plant_runtime_tick(s_state, dt, now, sim);
      last = now;
      if (s_force_publish) {
        s_force_publish = false;
        flags |= PLANT_PUBLISH_TELEMETRY | PLANT_PUBLISH_STATUS;
      }
      apply_flags(s_state, flags);
    }
  }
}

void plant_task_enqueue_command(const char *action, const char *json) {
  if (!s_cmdq) {
    return;
  }
  cmd_msg_t msg = {0};
  strncpy(msg.action, action, sizeof(msg.action) - 1);
  if (json) {
    strncpy(msg.json, json, sizeof(msg.json) - 1);
  } else {
    strncpy(msg.json, "{}", sizeof(msg.json) - 1);
  }
  if (xQueueSend(s_cmdq, &msg, 0) != pdTRUE) {
    ESP_LOGW(TAG, "command queue full, dropping %s", action);
  }
}

void plant_task_force_publish(void) { s_force_publish = true; }

esp_err_t plant_task_start(plant_state_t *state) {
  s_state = state;
  s_cmdq = xQueueCreate(8, sizeof(cmd_msg_t));
  if (!s_cmdq) {
    return ESP_ERR_NO_MEM;
  }

  gpio_config_t io = {
      .pin_bit_mask = 1ULL << CONFIG_PLANT_VALVE_GPIO,
      .mode = GPIO_MODE_OUTPUT,
      .pull_up_en = GPIO_PULLUP_DISABLE,
      .pull_down_en = GPIO_PULLDOWN_DISABLE,
      .intr_type = GPIO_INTR_DISABLE,
  };
  gpio_config(&io);
  set_valve_gpio(state->valve_open);

  BaseType_t ok = xTaskCreate(plant_loop, "plant", 4096, NULL, 5, NULL);
  return ok == pdPASS ? ESP_OK : ESP_FAIL;
}
