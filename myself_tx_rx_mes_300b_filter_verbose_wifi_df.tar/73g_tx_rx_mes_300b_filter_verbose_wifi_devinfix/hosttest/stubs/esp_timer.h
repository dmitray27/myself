#pragma once
#include <stdint.h>
/* Host stub: sample-driven virtual clock (advanced by the test harness). */
extern int64_t g_virtual_us;
static inline int64_t esp_timer_get_time(void) { return g_virtual_us; }
