#include "mqtt311.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void put_u16(uint8_t *p, uint16_t v) {
  p[0] = (uint8_t)((v >> 8) & 0xFF);
  p[1] = (uint8_t)(v & 0xFF);
}

static uint16_t get_u16(const uint8_t *p) {
  return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static int put_str(uint8_t *p, size_t cap, const char *s) {
  size_t n = strlen(s);
  if (n + 2 > cap) {
    return -1;
  }
  put_u16(p, (uint16_t)n);
  memcpy(p + 2, s, n);
  return (int)(2 + n);
}

static int encode_remaining(uint8_t *buf, int length) {
  int n = 0;
  do {
    uint8_t d = (uint8_t)(length % 128);
    length /= 128;
    if (length > 0) {
      d |= 0x80;
    }
    buf[n++] = d;
  } while (length > 0 && n < 4);
  return n;
}

static int decode_remaining(const uint8_t *buf, size_t avail, int *value,
                            int *consumed) {
  int multiplier = 1;
  int v = 0;
  size_t i = 0;
  uint8_t encoded;
  do {
    if (i >= avail) {
      return 0; /* need more */
    }
    encoded = buf[i++];
    v += (encoded & 127) * multiplier;
    multiplier *= 128;
    if (multiplier > 128 * 128 * 128) {
      return -1;
    }
  } while (encoded & 128);
  *value = v;
  *consumed = (int)i;
  return 1;
}

static int sock_write_all(int fd, const uint8_t *buf, size_t n) {
  size_t off = 0;
  while (off < n) {
    ssize_t w = send(fd, buf + off, n - off, 0);
    if (w < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    off += (size_t)w;
  }
  return 0;
}

static int tcp_connect(const char *host, int port) {
  char portstr[16];
  snprintf(portstr, sizeof(portstr), "%d", port);
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo *res = NULL;
  int err = getaddrinfo(host, portstr, &hints, &res);
  if (err != 0) {
    fprintf(stderr, "mqtt: getaddrinfo(%s): %s\n", host, gai_strerror(err));
    return -1;
  }
  int fd = -1;
  for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
    fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) {
      continue;
    }
    if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
      break;
    }
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  return fd;
}

int mqtt_connect(mqtt_client_t *c, const char *host, int port,
                 const char *client_id, const char *will_topic,
                 const char *will_payload, uint16_t keepalive_s) {
  memset(c, 0, sizeof(*c));
  c->fd = -1;
  c->port = port;
  c->keepalive = keepalive_s ? keepalive_s : 30;
  c->packet_id = 1;
  strncpy(c->client_id, client_id, sizeof(c->client_id) - 1);
  strncpy(c->host, host, sizeof(c->host) - 1);
  if (will_topic) {
    strncpy(c->will_topic, will_topic, sizeof(c->will_topic) - 1);
  }
  if (will_payload) {
    strncpy(c->will_payload, will_payload, sizeof(c->will_payload) - 1);
  }

  int fd = tcp_connect(host, port);
  if (fd < 0) {
    return -1;
  }

  uint8_t vh[1024];
  size_t off = 0;
  int n = put_str(vh + off, sizeof(vh) - off, "MQTT");
  if (n < 0) {
    close(fd);
    return -1;
  }
  off += (size_t)n;
  vh[off++] = 4; /* protocol level 3.1.1 */
  uint8_t flags = 0;
  /* clean session = 0 (persistent) + will flag + will qos1 + will retain */
  if (c->will_topic[0]) {
    flags |= 0x04; /* will */
    flags |= 0x08; /* will QoS 1 (bit 3) */
    flags |= 0x20; /* will retain */
  }
  vh[off++] = flags;
  put_u16(vh + off, c->keepalive);
  off += 2;
  n = put_str(vh + off, sizeof(vh) - off, c->client_id);
  if (n < 0) {
    close(fd);
    return -1;
  }
  off += (size_t)n;
  if (c->will_topic[0]) {
    n = put_str(vh + off, sizeof(vh) - off, c->will_topic);
    if (n < 0) {
      close(fd);
      return -1;
    }
    off += (size_t)n;
    n = put_str(vh + off, sizeof(vh) - off, c->will_payload);
    if (n < 0) {
      close(fd);
      return -1;
    }
    off += (size_t)n;
  }

  uint8_t pkt[1040];
  pkt[0] = 0x10; /* CONNECT */
  int rl = encode_remaining(pkt + 1, (int)off);
  memcpy(pkt + 1 + rl, vh, off);
  if (sock_write_all(fd, pkt, 1 + (size_t)rl + off) != 0) {
    close(fd);
    return -1;
  }

  /* Wait for CONNACK */
  uint8_t hdr[4];
  ssize_t r = recv(fd, hdr, 4, MSG_WAITALL);
  if (r != 4 || hdr[0] != 0x20 || hdr[1] != 0x02 || hdr[3] != 0x00) {
    fprintf(stderr, "mqtt: CONNACK failed (rc=%d)\n", r == 4 ? hdr[3] : -1);
    close(fd);
    return -1;
  }

  c->fd = fd;
  c->connected = true;
  return 0;
}

static uint16_t next_id(mqtt_client_t *c) {
  uint16_t id = c->packet_id++;
  if (c->packet_id == 0) {
    c->packet_id = 1;
  }
  return id;
}

int mqtt_publish(mqtt_client_t *c, const char *topic, const char *payload,
                 int qos, bool retain) {
  if (!c->connected || c->fd < 0) {
    return -1;
  }
  size_t plen = payload ? strlen(payload) : 0;
  uint8_t vh[MQTT_TOPIC_MAX + 8 + MQTT_PAYLOAD_MAX];
  int n = put_str(vh, sizeof(vh), topic);
  if (n < 0) {
    return -1;
  }
  size_t off = (size_t)n;
  uint16_t pid = 0;
  if (qos >= 1) {
    pid = next_id(c);
    if (off + 2 > sizeof(vh)) {
      return -1;
    }
    put_u16(vh + off, pid);
    off += 2;
  }
  if (off + plen > sizeof(vh)) {
    return -1;
  }
  if (plen) {
    memcpy(vh + off, payload, plen);
  }
  off += plen;

  uint8_t pkt[sizeof(vh) + 8];
  uint8_t type = 0x30;
  if (qos == 1) {
    type |= 0x02;
  }
  if (retain) {
    type |= 0x01;
  }
  pkt[0] = type;
  int rl = encode_remaining(pkt + 1, (int)off);
  memcpy(pkt + 1 + rl, vh, off);
  if (sock_write_all(c->fd, pkt, 1 + (size_t)rl + off) != 0) {
    c->connected = false;
    return -1;
  }
  return 0;
}

int mqtt_subscribe(mqtt_client_t *c, const char *topic_filter, int qos) {
  if (!c->connected || c->fd < 0) {
    return -1;
  }
  uint8_t vh[MQTT_TOPIC_MAX + 8];
  uint16_t pid = next_id(c);
  put_u16(vh, pid);
  size_t off = 2;
  int n = put_str(vh + off, sizeof(vh) - off, topic_filter);
  if (n < 0) {
    return -1;
  }
  off += (size_t)n;
  vh[off++] = (uint8_t)qos;

  uint8_t pkt[sizeof(vh) + 8];
  pkt[0] = 0x82; /* SUBSCRIBE, flags 0010 */
  int rl = encode_remaining(pkt + 1, (int)off);
  memcpy(pkt + 1 + rl, vh, off);
  if (sock_write_all(c->fd, pkt, 1 + (size_t)rl + off) != 0) {
    c->connected = false;
    return -1;
  }
  return 0;
}

int mqtt_disconnect(mqtt_client_t *c) {
  if (c->fd >= 0) {
    uint8_t pkt[2] = {0xE0, 0x00};
    (void)sock_write_all(c->fd, pkt, 2);
    close(c->fd);
  }
  c->fd = -1;
  c->connected = false;
  return 0;
}

static int send_puback(mqtt_client_t *c, uint16_t pid) {
  uint8_t pkt[4] = {0x40, 0x02, (uint8_t)(pid >> 8), (uint8_t)(pid & 0xFF)};
  return sock_write_all(c->fd, pkt, 4);
}

static int send_pingreq(mqtt_client_t *c) {
  uint8_t pkt[2] = {0xC0, 0x00};
  return sock_write_all(c->fd, pkt, 2);
}

static int handle_packet(mqtt_client_t *c, uint8_t type, const uint8_t *body,
                         int body_len) {
  uint8_t ptype = type >> 4;
  if (ptype == 3) { /* PUBLISH */
    int qos = (type >> 1) & 0x03;
    if (body_len < 2) {
      return -1;
    }
    uint16_t tlen = get_u16(body);
    if (2 + tlen > body_len) {
      return -1;
    }
    char topic[MQTT_TOPIC_MAX];
    size_t copy = tlen < sizeof(topic) - 1 ? tlen : sizeof(topic) - 1;
    memcpy(topic, body + 2, copy);
    topic[copy] = '\0';
    int idx = 2 + tlen;
    uint16_t pid = 0;
    if (qos > 0) {
      if (idx + 2 > body_len) {
        return -1;
      }
      pid = get_u16(body + idx);
      idx += 2;
    }
    const uint8_t *payload = body + idx;
    int plen = body_len - idx;
    char pbuf[MQTT_PAYLOAD_MAX];
    size_t pc = (size_t)plen < sizeof(pbuf) - 1 ? (size_t)plen : sizeof(pbuf) - 1;
    memcpy(pbuf, payload, pc);
    pbuf[pc] = '\0';
    if (qos == 1) {
      (void)send_puback(c, pid);
    }
    if (c->on_publish) {
      c->on_publish(topic, pbuf, pc, c->user);
    }
  }
  /* CONNACK/PUBACK/SUBACK/PINGRESP: nothing to do */
  return 0;
}

int mqtt_poll(mqtt_client_t *c, int timeout_ms, int64_t now_ms) {
  if (!c->connected || c->fd < 0) {
    return -1;
  }

  if (c->last_activity_ms == 0) {
    c->last_activity_ms = now_ms;
  }
  if ((now_ms - c->last_activity_ms) > (int64_t)c->keepalive * 800) {
    if (send_pingreq(c) != 0) {
      c->connected = false;
      return -1;
    }
    c->last_activity_ms = now_ms;
  }

  struct pollfd pfd = {.fd = c->fd, .events = POLLIN, .revents = 0};
  int pr = poll(&pfd, 1, timeout_ms);
  if (pr < 0) {
    if (errno == EINTR) {
      return 0;
    }
    c->connected = false;
    return -1;
  }
  if (pr == 0) {
    return 0;
  }
  if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
    c->connected = false;
    return -1;
  }
  if (!(pfd.revents & POLLIN)) {
    return 0;
  }

  uint8_t tmp[512];
  ssize_t r = recv(c->fd, tmp, sizeof(tmp), 0);
  if (r <= 0) {
    c->connected = false;
    return -1;
  }
  if (c->rx_len + (size_t)r > sizeof(c->rx)) {
    c->rx_len = 0; /* drop overflow; reconnect will recover */
    return -1;
  }
  memcpy(c->rx + c->rx_len, tmp, (size_t)r);
  c->rx_len += (size_t)r;
  c->last_activity_ms = now_ms;

  while (c->rx_len >= 2) {
    int remaining = 0, consumed = 0;
    int dec = decode_remaining(c->rx + 1, c->rx_len - 1, &remaining, &consumed);
    if (dec == 0) {
      break;
    }
    if (dec < 0) {
      c->rx_len = 0;
      return -1;
    }
    size_t total = 1 + (size_t)consumed + (size_t)remaining;
    if (c->rx_len < total) {
      break;
    }
    if (handle_packet(c, c->rx[0], c->rx + 1 + consumed, remaining) != 0) {
      return -1;
    }
    memmove(c->rx, c->rx + total, c->rx_len - total);
    c->rx_len -= total;
  }
  return 0;
}
