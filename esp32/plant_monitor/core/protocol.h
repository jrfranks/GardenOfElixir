#ifndef PROTOCOL_H
#define PROTOCOL_H

#include "plant_runtime.h"

#include <stddef.h>

/*
 * Exact v1 topic schema from docs/PHASE1_ARCHITECTURE_AND_PLAN.md §3.1
 * and dashboard MqttBridge. Real devices MUST publish the aggregate
 * /sensors topic — that is the only path FleetState uses for metrics.
 */

#define PROTO_FW_VERSION "0.1.0"

void protocol_dt_topic(char *out, size_t n, const char *device_id,
                       const char *metric);
void protocol_status_topic(char *out, size_t n, const char *device_id);
void protocol_cmd_filter(char *out, size_t n, const char *device_id);

/* Returns pointer into `topic` for the action name, or NULL if not ours. */
const char *protocol_action_from_topic(const char *topic,
                                       const char *device_id);

int protocol_encode_metric(char *out, size_t n, double value, const char *unit,
                           int64_t ts_ms);
int protocol_encode_sensors(char *out, size_t n, const plant_state_t *s);
int protocol_encode_status(char *out, size_t n, const plant_state_t *s,
                           const char *iso8601, int online);
int protocol_encode_lwt(char *out, size_t n);

#endif /* PROTOCOL_H */
