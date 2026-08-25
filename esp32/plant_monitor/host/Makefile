# Host-native build of the ESP32 plant monitor core + MQTT 3.1.1 client.
# No ESP-IDF required. Used by CI and `make esp32-host`.

CC ?= gcc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O2 -D_POSIX_C_SOURCE=200809L
CPPFLAGS ?= -I../core -I.
LDLIBS ?= -lm

CORE = ../core/plant_physics.c ../core/json_util.c ../core/protocol.c \
       ../core/plant_runtime.c
HOST = mqtt311.c platform.c

.PHONY: all test clean run

all: plant_monitor_host

plant_monitor_host: main.c $(HOST) $(CORE)
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ main.c $(HOST) $(CORE) $(LDLIBS)

test_physics: test_physics.c ../core/plant_physics.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ test_physics.c ../core/plant_physics.c $(LDLIBS)

test_runtime: test_runtime.c $(CORE)
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ test_runtime.c $(CORE) $(LDLIBS)

test: test_physics test_runtime
	./test_physics
	./test_runtime

run: plant_monitor_host
	./plant_monitor_host

clean:
	rm -f plant_monitor_host test_physics test_runtime *.o
