#include "tx_ad9851.h"
#include "afsk_protocol.h"
#include "driver/gpio.h"
#include "driver/gptimer.h"
#include "esp_log.h"
#include "esp_attr.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "soc/gpio_reg.h"
#include "esp_rom_sys.h"
#include <string.h>

static const char *TAG = "TX_AD9851";

static uint32_t freq_word_mark;
static uint32_t freq_word_space;
static uint32_t freq_word_silence;

volatile bool tx_bit_buffer[TX_BIT_BUFFER_SIZE];
volatile uint32_t tx_bit_r_idx = 0;
volatile uint32_t tx_bit_w_idx = 0;
static volatile bool tx_is_active = false;

static gptimer_handle_t tx_timer = NULL;
static SemaphoreHandle_t tx_idle_sem = NULL;
static SemaphoreHandle_t tx_mutex = NULL;
/* Task that currently holds tx_mutex: wait_idle() releases the mutex only for
 * the task that took it in send_block(), so a stray wait_idle() elsewhere
 * cannot hand the transmitter to someone else. */
static volatile TaskHandle_t tx_owner = NULL;

#define BIT_DURATION_US (1000000UL / BAUD_RATE)

/* Between blocks the DDS is not just tuned to 0 Hz but put into power-down
 * (control bit W34): a running DAC/comparator keeps feeding the audio path and
 * the receiver's ADC, which shows up as a stray carrier and false preambles.
 * Set to 0 if the hardware misbehaves when the output is powered down. */
#ifndef TX_POWER_DOWN_WHEN_IDLE
#define TX_POWER_DOWN_WHEN_IDLE 1
#endif

static void precompute_freq_words(void) {
    freq_word_mark = (uint32_t)(((uint64_t)MARK_FREQ << 32) / REF_CLOCK);
    freq_word_space = (uint32_t)(((uint64_t)SPACE_FREQ << 32) / REF_CLOCK);
    freq_word_silence = 0;

    ESP_LOGI(TAG, "Freq words precomputed:");
    ESP_LOGI(TAG, "  MARK  (%d Hz): 0x%08lX", MARK_FREQ, (unsigned long)freq_word_mark);
    ESP_LOGI(TAG, "  SPACE (%d Hz): 0x%08lX", SPACE_FREQ, (unsigned long)freq_word_space);
}

static void reset_ad9851(void) {
    gpio_set_level(PIN_RESET, 1);
    vTaskDelay(pdMS_TO_TICKS(5));
    gpio_set_level(PIN_RESET, 0);
    vTaskDelay(pdMS_TO_TICKS(5));

    gpio_set_level(PIN_W_CLK, 0);
    gpio_set_level(PIN_FQ_UD, 0);

    gpio_set_level(PIN_W_CLK, 1);
    gpio_set_level(PIN_W_CLK, 0);

    gpio_set_level(PIN_FQ_UD, 1);
    gpio_set_level(PIN_FQ_UD, 0);
}

/* Loads the 40-bit word: 32 frequency bits (LSB first) followed by the control
 * byte W32..W39 = [x6 refclk multiplier][0][power-down][5-bit phase]. */
static void IRAM_ATTR set_frequency_fast(uint32_t freq_word, bool power_down) {
    REG_WRITE(GPIO_OUT_W1TC_REG, (1 << PIN_FQ_UD));

    for (int i = 0; i < 32; i++) {
        if ((freq_word >> i) & 1) {
            REG_WRITE(GPIO_OUT_W1TS_REG, (1 << PIN_DATA));
        } else {
            REG_WRITE(GPIO_OUT_W1TC_REG, (1 << PIN_DATA));
        }
        REG_WRITE(GPIO_OUT_W1TS_REG, (1 << PIN_W_CLK));
        REG_WRITE(GPIO_OUT_W1TC_REG, (1 << PIN_W_CLK));
    }

    for (int i = 0; i < 8; i++) {
        if (i == 2 && power_down) {
            REG_WRITE(GPIO_OUT_W1TS_REG, (1 << PIN_DATA));
        } else {
            REG_WRITE(GPIO_OUT_W1TC_REG, (1 << PIN_DATA));
        }
        REG_WRITE(GPIO_OUT_W1TS_REG, (1 << PIN_W_CLK));
        REG_WRITE(GPIO_OUT_W1TC_REG, (1 << PIN_W_CLK));
    }

    REG_WRITE(GPIO_OUT_W1TC_REG, (1 << PIN_DATA));

    REG_WRITE(GPIO_OUT_W1TS_REG, (1 << PIN_FQ_UD));
    REG_WRITE(GPIO_OUT_W1TC_REG, (1 << PIN_FQ_UD));
}

static bool IRAM_ATTR on_tx_timer_isr(gptimer_handle_t timer,
                                      const gptimer_alarm_event_data_t *edata,
                                      void *user_ctx) {
    BaseType_t high_priority_task_awoken = pdFALSE;

    if (tx_bit_r_idx != tx_bit_w_idx) {
        bool bit = tx_bit_buffer[tx_bit_r_idx];
        tx_bit_r_idx = (tx_bit_r_idx + 1) % TX_BIT_BUFFER_SIZE;
        set_frequency_fast(bit ? freq_word_mark : freq_word_space, false);
    } else {
        tx_is_active = false;
        gptimer_stop(timer);
        set_frequency_fast(freq_word_silence, TX_POWER_DOWN_WHEN_IDLE);

        if (tx_idle_sem) {
            xSemaphoreGiveFromISR(tx_idle_sem, &high_priority_task_awoken);
        }
    }

    return high_priority_task_awoken == pdTRUE;
}

void tx_ad9851_ptt(bool key) {
#if TX_PTT_ENABLE
    gpio_set_level(PIN_PTT, key ? PTT_ACTIVE_LEVEL : !PTT_ACTIVE_LEVEL);
#else
    (void)key;
#endif
}

static void init_gpio(void) {
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << PIN_FQ_UD) | (1ULL << PIN_W_CLK) |
                        (1ULL << PIN_DATA) | (1ULL << PIN_RESET)
#if TX_PTT_ENABLE
                        | (1ULL << PIN_PTT)
#endif
                        ,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io_conf);

    gpio_set_level(PIN_FQ_UD, 0);
    gpio_set_level(PIN_W_CLK, 0);
    gpio_set_level(PIN_DATA, 0);
    gpio_set_level(PIN_RESET, 0);

    tx_ad9851_ptt(false);
}

static void init_gptimer(void) {
    gptimer_config_t timer_config = {
        .clk_src = GPTIMER_CLK_SRC_DEFAULT,
        .direction = GPTIMER_COUNT_UP,
        .resolution_hz = 1000000,
    };
    ESP_ERROR_CHECK(gptimer_new_timer(&timer_config, &tx_timer));

    gptimer_alarm_config_t alarm_config = {
        .alarm_count = BIT_DURATION_US,
        .reload_count = 0,
        .flags = {
            .auto_reload_on_alarm = true,
        },
    };
    ESP_ERROR_CHECK(gptimer_set_alarm_action(tx_timer, &alarm_config));

    gptimer_event_callbacks_t cbs = {
        .on_alarm = on_tx_timer_isr,
    };
    ESP_ERROR_CHECK(gptimer_register_event_callbacks(tx_timer, &cbs, NULL));
    ESP_ERROR_CHECK(gptimer_enable(tx_timer));

    ESP_LOGI(TAG, "GPTimer initialized: %lu us per bit", (unsigned long)BIT_DURATION_US);
}

void tx_ad9851_init(void) {
    ESP_LOGI(TAG, "Initializing AD9851 transmitter...");

    precompute_freq_words();
    init_gpio();
    reset_ad9851();
    init_gptimer();

    tx_idle_sem = xSemaphoreCreateBinary();
    tx_mutex = xSemaphoreCreateMutex();
    tx_owner = NULL;

    set_frequency_fast(freq_word_silence, TX_POWER_DOWN_WHEN_IDLE);

    ESP_LOGI(TAG, "AD9851 transmitter ready - SILENT mode%s",
             TX_POWER_DOWN_WHEN_IDLE ? " (output powered down)" : "");
}

bool tx_ad9851_send_block(const uint8_t *data, size_t len) {
    if (xSemaphoreTake(tx_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
        ESP_LOGW(TAG, "Transmitter busy, cannot send block");
        return false;
    }
    tx_owner = xTaskGetCurrentTaskHandle();

    if (tx_is_active) {
        ESP_LOGW(TAG, "Transmission already active, cannot send");
        tx_owner = NULL;
        xSemaphoreGive(tx_mutex);
        return false;
    }

    tx_bit_r_idx = 0;
    tx_bit_w_idx = 0;
    for (size_t i = 0; i < TX_BIT_BUFFER_SIZE; i++) {
        tx_bit_buffer[i] = false;
    }

    ESP_LOGI(TAG, "Sending block: %zu bytes", len);

    afsk_serialize_block_ring(data, len, tx_bit_buffer, &tx_bit_w_idx,
                              &tx_bit_r_idx, TX_BIT_BUFFER_SIZE);

    /* Wake the output up before the first bit is clocked out. */
    set_frequency_fast(freq_word_silence, false);

#if TX_PTT_ENABLE
    tx_ad9851_ptt(true);
    vTaskDelay(pdMS_TO_TICKS(PTT_LEAD_MS));
#endif

    /* Drop a token left over from a previous transmission that timed out:
     * otherwise the next wait_idle() returns at once, mid-block. */
    if (tx_idle_sem) {
        xSemaphoreTake(tx_idle_sem, 0);
    }

    tx_is_active = true;
    ESP_ERROR_CHECK(gptimer_start(tx_timer));

    return true;
}

bool tx_ad9851_is_active(void) {
    return tx_is_active;
}

void tx_ad9851_wait_idle(void) {
    if (tx_is_active && tx_idle_sem) {
        if (xSemaphoreTake(tx_idle_sem, pdMS_TO_TICKS(TX_IDLE_TIMEOUT_MS)) != pdTRUE) {
            ESP_LOGW(TAG, "TX idle timeout after %d ms", TX_IDLE_TIMEOUT_MS);
        }
    }

#if TX_PTT_ENABLE
    vTaskDelay(pdMS_TO_TICKS(PTT_TAIL_MS));
    tx_ad9851_ptt(false);
#endif

    if (tx_owner == xTaskGetCurrentTaskHandle()) {
        tx_owner = NULL;
        xSemaphoreGive(tx_mutex);
    }
}
