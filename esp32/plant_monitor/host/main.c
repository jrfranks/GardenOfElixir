#include "mqtt311.h"
#include "plant_runtime.h"
#include "platform.h"
#include "protocol.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/*
 * Host-native ESP32 plant monitor. Same C core + MQTT schema as the ESP-IDF
 * firmware; runs on Linux so `make demo-firmware` / CI can exercise real C
 * without a Xtensa toolchain. On hardware, main/app_main.c wraps this core
 * with Wi-Fi + esp_mqtt + FreeRTOS.
 */

static volatile sig_atomic_t g_stop = 0;
static mqtt_client_t g_mqtt;
static plant_state_t g_plant;

static void on_sig(int sig) {
  (void)sig;
  g_stop = 1;
}

static void publish_telemetry(plant_state_t *s) {
  char topic[192], payload[512];
  int64_t ts = (int64_t)time(NULL) * 1000;

  protocol_dt_topic(topic, sizeof(topic), s->device_id, "sensors");
  protocol_encode_sensors(payload, sizeof(payload), s);
  mqtt_publish(&g_mqtt, topic, payload, 0, false);

  protocol_dt_topic(topic, sizeof(topic), s->device_id, "soil_moisture");
  protocol_encode_metric(payload, sizeof(payload), s->soil_moisture, "%", ts);
  mqtt_publish(&g_mqtt, topic, payload, 0, false);

  protocol_dt_topic(topic, sizeof(topic), s->device_id, "temperature");
  protocol_encode_metric(payload, sizeof(payload), s->temperature, "C", ts);
  mqtt_publish(&g_mqtt, topic, payload, 0, false);

  protocol_dt_topic(topic, sizeof(topic), s->device_id, "humidity");
  protocol_encode_metric(payload, sizeof(payload), s->humidity, "%", ts);
  mqtt_publish(&g_mqtt, topic, payload, 0, false);

  protocol_dt_topic(topic, sizeof(topic), s->device_id, "battery");
  protocol_encode_metric(payload, sizeof(payload), s->battery, "%", ts);
  mqtt_publish(&g_mqtt, topic, payload, 0, false);
}

static void publish_status(plant_state_t *s, int online) {
  char topic[192], payload[768], iso[40];
  platform_iso8601(iso, sizeof(iso));
  protocol_status_topic(topic, sizeof(topic), s->device_id);
  protocol_encode_status(payload, sizeof(payload), s, iso, online);
  mqtt_publish(&g_mqtt, topic, payload, 1, true);
}

static void on_publish(const char *topic, const char *payload, size_t len,
                       void *user) {
  (void)len;
  plant_state_t *s = user;
  const char *action = protocol_action_from_topic(topic, s->device_id);
  if (!action) {
    return;
  }
  fprintf(stderr, "esp32-host: command %s payload=%s\n", action, payload);
  int flags = plant_runtime_apply_command(s, action, payload, platform_now_ms());
  if (flags < 0) {
    fprintf(stderr, "esp32-host: reboot requested — exiting so supervisor can restart\n");
    g_stop = 1;
    return;
  }
  if (flags & PLANT_PUBLISH_TELEMETRY) {
    publish_telemetry(s);
  }
  if (flags & PLANT_PUBLISH_STATUS) {
    publish_status(s, 1);
  }
}

int main(int argc, char **argv) {
  (void)argc;
  (void)argv;
  signal(SIGINT, on_sig);
  signal(SIGTERM, on_sig);

  const char *device_id = platform_env("DEVICE_ID", "esp32-fw-001");
  const char *host = platform_env("MQTT_HOST", "127.0.0.1");
  int port = atoi(platform_env("MQTT_PORT", "1883"));

  plant_runtime_init(&g_plant, device_id, platform_now_ms());

  char will_topic[192], will_payload[160];
  protocol_status_topic(will_topic, sizeof(will_topic), g_plant.device_id);
  protocol_encode_lwt(will_payload, sizeof(will_payload));

  fprintf(stderr, "esp32-host: connecting mqtt://%s:%d as %s\n", host, port,
          g_plant.device_id);

  int attempts = 0;
  while (!g_stop) {
    g_mqtt.on_publish = on_publish;
    g_mqtt.user = &g_plant;
    if (mqtt_connect(&g_mqtt, host, port, g_plant.device_id, will_topic,
                     will_payload, 30) != 0) {
      int delay = 1 << (attempts < 5 ? attempts : 5);
      fprintf(stderr, "esp32-host: connect failed, retry in %ds\n", delay);
      attempts++;
      sleep((unsigned)delay);
      continue;
    }
    attempts = 0;
    g_mqtt.on_publish = on_publish;
    g_mqtt.user = &g_plant;

    char filter[192];
    protocol_cmd_filter(filter, sizeof(filter), g_plant.device_id);
    if (mqtt_subscribe(&g_mqtt, filter, 1) != 0) {
      fprintf(stderr, "esp32-host: subscribe failed\n");
      mqtt_disconnect(&g_mqtt);
      continue;
    }

    publish_status(&g_plant, 1);
    publish_telemetry(&g_plant);
    fprintf(stderr, "esp32-host: online, subscribed %s\n", filter);

    int64_t last_tick = platform_now_ms();
    int64_t sim_time = 0;
    while (!g_stop && g_mqtt.connected) {
      int64_t now = platform_now_ms();
      if (mqtt_poll(&g_mqtt, 100, now) != 0) {
        fprintf(stderr, "esp32-host: mqtt poll failed, reconnecting\n");
        break;
      }
      now = platform_now_ms();
      if (now - last_tick >= 200) {
        double dt = (double)(now - last_tick) / 1000.0;
        sim_time += now - last_tick;
        int flags = plant_runtime_tick(&g_plant, dt, now, sim_time);
        last_tick = now;
        if (flags & PLANT_PUBLISH_TELEMETRY) {
          publish_telemetry(&g_plant);
        }
        if (flags & PLANT_PUBLISH_STATUS) {
          publish_status(&g_plant, 1);
        }
      }
    }
    mqtt_disconnect(&g_mqtt);
    if (!g_stop) {
      sleep(1);
    }
  }

  /* Best-effort graceful offline (LWT covers unclean death). */
  if (mqtt_connect(&g_mqtt, host, port, g_plant.device_id, will_topic,
                   will_payload, 30) == 0) {
    g_mqtt.on_publish = NULL;
    publish_status(&g_plant, 0);
    mqtt_disconnect(&g_mqtt);
  }
  fprintf(stderr, "esp32-host: stopped\n");
  return 0;
}
