#include "mqtt_app.h"
#include "app_config.h"
#include "plant_task.h"
#include "protocol.h"

#include "esp_log.h"
#include "mqtt_client.h"

#include <string.h>

static const char *TAG = "mqtt";
static esp_mqtt_client_handle_t s_client;
static plant_state_t *s_state;
static volatile bool s_connected;

static void on_connected(void) {
  char filter[192];
  protocol_cmd_filter(filter, sizeof(filter), s_state->device_id);
  int mid = esp_mqtt_client_subscribe(s_client, filter, 1);
  ESP_LOGI(TAG, "subscribe %s mid=%d", filter, mid);
  plant_task_force_publish();
}

static void on_data(const char *topic, int topic_len, const char *data,
                    int data_len) {
  char tbuf[192];
  char pbuf[768];
  if (topic_len >= (int)sizeof(tbuf) || data_len >= (int)sizeof(pbuf)) {
    ESP_LOGW(TAG, "dropping oversized MQTT packet");
    return;
  }
  memcpy(tbuf, topic, (size_t)topic_len);
  tbuf[topic_len] = '\0';
  memcpy(pbuf, data, (size_t)data_len);
  pbuf[data_len] = '\0';

  const char *action = protocol_action_from_topic(tbuf, s_state->device_id);
  if (!action) {
    return;
  }
  ESP_LOGI(TAG, "cmd %s %s", action, pbuf);
  plant_task_enqueue_command(action, pbuf);
}

static void mqtt_event(void *args, esp_event_base_t base, int32_t id,
                       void *data) {
  (void)args;
  (void)base;
  esp_mqtt_event_handle_t ev = data;
  switch (id) {
  case MQTT_EVENT_CONNECTED:
    s_connected = true;
    ESP_LOGI(TAG, "connected");
    on_connected();
    break;
  case MQTT_EVENT_DISCONNECTED:
    s_connected = false;
    ESP_LOGW(TAG, "disconnected — esp_mqtt will retry");
    break;
  case MQTT_EVENT_DATA:
    on_data(ev->topic, ev->topic_len, ev->data, ev->data_len);
    break;
  case MQTT_EVENT_ERROR:
    ESP_LOGW(TAG, "error");
    break;
  default:
    break;
  }
}

esp_err_t plant_mqtt_start(plant_state_t *state) {
  s_state = state;
  /* esp_mqtt_client_init stores these pointers — they must outlive start(). */
  static char will_topic[192];
  static char will_payload[160];
  protocol_status_topic(will_topic, sizeof(will_topic), state->device_id);
  protocol_encode_lwt(will_payload, sizeof(will_payload));

  esp_mqtt_client_config_t cfg = {
      .broker.address.uri = CONFIG_PLANT_MQTT_URI,
      .credentials.client_id = state->device_id,
      .session.disable_clean_session = true,
      .session.keepalive = 30,
      .session.last_will.topic = will_topic,
      .session.last_will.msg = will_payload,
      .session.last_will.msg_len = strlen(will_payload),
      .session.last_will.qos = 1,
      .session.last_will.retain = true,
  };

  s_client = esp_mqtt_client_init(&cfg);
  if (!s_client) {
    return ESP_FAIL;
  }
  ESP_ERROR_CHECK(esp_mqtt_client_register_event(s_client, ESP_EVENT_ANY_ID,
                                                 mqtt_event, NULL));
  return esp_mqtt_client_start(s_client);
}

void plant_mqtt_publish(const char *topic, const char *payload, int qos,
                        bool retain) {
  if (!s_client || !s_connected) {
    return;
  }
  esp_mqtt_client_publish(s_client, topic, payload, 0, qos, retain ? 1 : 0);
}

bool plant_mqtt_is_connected(void) { return s_connected; }
