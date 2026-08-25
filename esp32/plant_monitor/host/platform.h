#ifndef PLATFORM_H
#define PLATFORM_H

#include <stddef.h>
#include <stdint.h>

int64_t platform_now_ms(void);
void platform_iso8601(char *out, size_t n);
const char *platform_env(const char *key, const char *fallback);

#endif
