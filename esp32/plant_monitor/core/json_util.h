#ifndef JSON_UTIL_H
#define JSON_UTIL_H

#include <stddef.h>

/*
 * Tiny extractors for the command payloads this firmware actually receives.
 * Not a general JSON library — on-device parsing of untrusted MQTT bodies
 * must not allocate or crash on garbage (mirrors MqttBridge's guarded parse).
 */

int json_has_key(const char *json, const char *key);
int json_get_int(const char *json, const char *key, int default_val);
double json_get_double(const char *json, const char *key, double default_val);
int json_get_bool(const char *json, const char *key, int default_val);

#endif /* JSON_UTIL_H */
