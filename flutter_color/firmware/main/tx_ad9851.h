#pragma once
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include "driver/gpio.h"
#include "afsk_common.h"

/* AD9851 control lines. Pin numbers come from Kconfig ("AFSK Pin
 * Configuration"), so the same sources build for WROOM and for S3 by
 * swapping sdkconfig.defaults. */
#define PIN_FQ_UD   ((gpio_num_t)CONFIG_PIN_FQ_UD)
#define PIN_W_CLK   ((gpio_num_t)CONFIG_PIN_W_CLK)
#define PIN_DATA    ((gpio_num_t)CONFIG_PIN_DATA)
#define PIN_RESET   ((gpio_num_t)CONFIG_PIN_RESET)

/* The bit-banging in set_frequency_fast() writes GPIO_OUT_W1TS/W1TC, which
 * only cover GPIO 0..31. A pin >= 32 (legal on S3) would shift out of range
 * and clock the DDS through the wrong register, so it is rejected here
 * instead of failing silently on the air. */
_Static_assert(CONFIG_PIN_FQ_UD < 32 && CONFIG_PIN_W_CLK < 32 &&
               CONFIG_PIN_DATA < 32 && CONFIG_PIN_RESET < 32,
               "AD9851 control pins must be GPIO < 32: set_frequency_fast() "
               "writes the low GPIO_OUT_W1TS/W1TC registers only");

/* DDS reference clock fed to the AD9851 (external 125 MHz oscillator,
 * 6x refclk multiplier disabled -> control byte = 0). */
#define REF_CLOCK   125000000ULL

/* PTT line for a voice radio. TX_PTT_ENABLE and the lead/tail timings live in
 * afsk_common.h: the block and timeout arithmetic depends on them. */
#define PIN_PTT             ((gpio_num_t)CONFIG_PIN_PTT)
#define PTT_ACTIVE_LEVEL    1       /* level that keys the radio */

/* One block must fit in the ring with a free slot to spare, otherwise
 * afsk_serialize_block() would drop bits (a truncated frame on the air). */
#define TX_BIT_BUFFER_SIZE  4096
_Static_assert(TX_BIT_BUFFER_SIZE > BLOCK_BITS + 1,
               "TX_BIT_BUFFER_SIZE must hold a full block: raise it after "
               "increasing PREAMBLE_BITS or MAX_BLOCK_LEN");

void tx_ad9851_init(void);
bool tx_ad9851_send_block(const uint8_t *data, size_t len);
bool tx_ad9851_is_active(void);
void tx_ad9851_wait_idle(void);

/* Manual keying, e.g. to hold the radio up across several blocks. */
void tx_ad9851_ptt(bool key);
