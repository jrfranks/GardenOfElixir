#include "platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

int64_t platform_now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

void platform_iso8601(char *out, size_t n) {
  time_t now = time(NULL);
  struct tm tm;
  gmtime_r(&now, &tm);
  strftime(out, n, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

const char *platform_env(const char *key, const char *fallback) {
  const char *v = getenv(key);
  if (v && v[0]) {
    return v;
  }
  return fallback;
}
