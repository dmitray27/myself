#pragma once
#include <stddef.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

/* Initialize Wi-Fi AP, HTTP and WebSocket servers. */
void wifi_link_init(void);

/* Get the FreeRTOS queue used to feed messages to the AFSK transmitter. */
QueueHandle_t wifi_link_get_tx_queue(void);

/* Broadcast "from:<id>:text" (or legacy "from:text") to all connected
   WebSocket clients. The [text] argument may contain the id prefix. */
void wifi_link_broadcast(const char *from, const char *text);
