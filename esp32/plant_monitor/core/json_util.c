#include "json_util.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

static const char *find_key(const char *json, const char *key) {
  if (!json || !key) {
    return NULL;
  }
  char quoted[80];
  size_t klen = strlen(key);
  if (klen + 3 >= sizeof(quoted)) {
    return NULL;
  }
  quoted[0] = '"';
  memcpy(quoted + 1, key, klen);
  quoted[klen + 1] = '"';
  quoted[klen + 2] = '\0';

  const char *p = json;
  while ((p = strstr(p, quoted)) != NULL) {
    const char *after = p + klen + 2;
    while (*after && isspace((unsigned char)*after)) {
      after++;
    }
    if (*after == ':') {
      after++;
      while (*after && isspace((unsigned char)*after)) {
        after++;
      }
      return after;
    }
    p++;
  }
  return NULL;
}

int json_has_key(const char *json, const char *key) {
  return find_key(json, key) != NULL;
}

int json_get_int(const char *json, const char *key, int default_val) {
  const char *v = find_key(json, key);
  if (!v || !*v) {
    return default_val;
  }
  if (*v == '"') {
    v++;
  }
  char *end = NULL;
  long n = strtol(v, &end, 10);
  if (end == v) {
    return default_val;
  }
  return (int)n;
}

double json_get_double(const char *json, const char *key, double default_val) {
  const char *v = find_key(json, key);
  if (!v || !*v) {
    return default_val;
  }
  if (*v == '"') {
    v++;
  }
  char *end = NULL;
  double n = strtod(v, &end);
  if (end == v) {
    return default_val;
  }
  return n;
}

int json_get_bool(const char *json, const char *key, int default_val) {
  const char *v = find_key(json, key);
  if (!v || !*v) {
    return default_val;
  }
  if (strncmp(v, "true", 4) == 0 || *v == '1') {
    return 1;
  }
  if (strncmp(v, "false", 5) == 0 || *v == '0') {
    return 0;
  }
  if (*v == '"') {
    if (strncmp(v + 1, "true", 4) == 0 || v[1] == '1') {
      return 1;
    }
    if (strncmp(v + 1, "false", 5) == 0 || v[1] == '0') {
      return 0;
    }
  }
  return default_val;
}
