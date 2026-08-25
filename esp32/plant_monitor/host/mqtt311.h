#ifndef MQTT311_H
#define MQTT311_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Minimal MQTT 3.1.1 client (CONNECT, PUBLISH QoS 0/1, SUBSCRIBE, PING,
 * DISCONNECT) over a TCP socket. Enough for the plant-monitor wire schema
 * without pulling libmosquitto. Not a general-purpose client.
 */

#define MQTT_CLIENT_ID_MAX 64
#define MQTT_TOPIC_MAX 192
#define MQTT_PAYLOAD_MAX 768
#define MQTT_RX_MAX 2048

typedef void (*mqtt_publish_cb)(const char *topic, const char *payload,
                                size_t payload_len, void *user);

typedef struct {
  int fd;
  char client_id[MQTT_CLIENT_ID_MAX];
  char host[128];
  int port;
  uint16_t keepalive;
  uint16_t packet_id;
  bool connected;
  uint8_t rx[MQTT_RX_MAX];
  size_t rx_len;
  int64_t last_activity_ms;
  mqtt_publish_cb on_publish;
  void *user;
  char will_topic[MQTT_TOPIC_MAX];
  char will_payload[MQTT_PAYLOAD_MAX];
} mqtt_client_t;

int mqtt_connect(mqtt_client_t *c, const char *host, int port,
                 const char *client_id, const char *will_topic,
                 const char *will_payload, uint16_t keepalive_s);

int mqtt_publish(mqtt_client_t *c, const char *topic, const char *payload,
                 int qos, bool retain);
int mqtt_subscribe(mqtt_client_t *c, const char *topic_filter, int qos);
int mqtt_disconnect(mqtt_client_t *c);

/* Drive the socket: read packets, send PINGREQ if needed. timeout_ms for poll. */
int mqtt_poll(mqtt_client_t *c, int timeout_ms, int64_t now_ms);

#endif /* MQTT311_H */
