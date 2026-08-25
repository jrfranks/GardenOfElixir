#ifndef APP_CONFIG_H
#define APP_CONFIG_H

#include "sdkconfig.h"

#ifndef CONFIG_PLANT_DEVICE_ID
#define CONFIG_PLANT_DEVICE_ID "esp32-fw-001"
#endif
#ifndef CONFIG_PLANT_MQTT_URI
#define CONFIG_PLANT_MQTT_URI "mqtt://192.168.1.10:1883"
#endif
#ifndef CONFIG_PLANT_WIFI_SSID
#define CONFIG_PLANT_WIFI_SSID "garden"
#endif
#ifndef CONFIG_PLANT_WIFI_PASSWORD
#define CONFIG_PLANT_WIFI_PASSWORD "elixir"
#endif
#ifndef CONFIG_PLANT_VALVE_GPIO
#define CONFIG_PLANT_VALVE_GPIO 2
#endif
#ifndef CONFIG_PLANT_TICK_MS
#define CONFIG_PLANT_TICK_MS 200
#endif

#endif
