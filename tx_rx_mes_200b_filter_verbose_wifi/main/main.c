#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <inttypes.h>
#include <unistd.h>
#include <errno.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "driver/i2s_std.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_heap_caps.h"
#include "nvs_flash.h"
#include "tx_ad9851.h"
#include "afsk_protocol.h"
#include "afsk_decoder.h"
#include "wifi_link.h"

static const char *TAG = "MAIN";

/* ---------------- TX (core 0) ---------------- */
/* MAX_BLOCK_LEN, BLOCK_GAP_MS and the derived block timings live in
 * afsk_common.h: TX, RX and the timeouts have to agree on them. */
#define BUF_SIZE        8192

/* ---------------- RX (core 1) ---------------- */
/* I2S pins come from Kconfig ("AFSK Pin Configuration") so the same sources
 * build for WROOM and for S3 by swapping sdkconfig.defaults. */
#define I2S_BCK_PIN     ((gpio_num_t)CONFIG_PIN_I2S_BCK)
#define I2S_WS_PIN      ((gpio_num_t)CONFIG_PIN_I2S_WS)
#define I2S_DATA_PIN    ((gpio_num_t)CONFIG_PIN_I2S_DATA)
#define SAMPLES_PER_BIT (SAMPLE_RATE / BAUD_RATE)

/* I2S slot layout used below: 24 data bits in a 32-bit slot, both slots
 * enabled. The sample extraction (>> RX_SAMPLE_SHIFT, step of
 * RX_SLOTS_PER_FRAME) is derived from these constants, so the slot config and
 * the unpacking cannot drift apart. */
#define RX_DATA_BITS        24
#define RX_SLOT_BITS        32
#define RX_SAMPLE_SHIFT     (RX_SLOT_BITS - RX_DATA_BITS)
#define RX_SLOTS_PER_FRAME  2

#define RX_ASSEMBLY_MAX 8192
#define MESSAGE_IDLE_MS (BLOCK_TIME_MS + BLOCK_TIME_MS / 2)

static afsk_decoder_t decoder;
static afsk_message_t message;

/* Ассемблер-сборщик сообщений вынесен в глобальные массивы: так исключаем
   возможность повреждения указателей на стеке rx_task. */
static char s_assembly[RX_ASSEMBLY_MAX + 1];
static char s_broadcast_buf[RX_ASSEMBLY_MAX + 64];
static int s_assembly_len = 0;
static uint32_t s_assembly_blocks = 0;
static uint32_t s_assembly_dropped = 0;
static bool s_assembling = false;

static void tx_send_message(const char *text, size_t len)
{
    if (len == 0) {
        return;
    }

    int blocks = 0;
    for (int s = 0; s < (int)len; ) {
        s += afsk_utf8_block_len(text, s, (int)len, MAX_BLOCK_LEN);
        blocks++;
    }
    ESP_LOGI(TAG, "Message: %d bytes, Blocks: %d", (int)len, blocks);

    int start = 0;
    for (int i = 0; i < blocks; i++) {
        int block_len = afsk_utf8_block_len(text, start, (int)len, MAX_BLOCK_LEN);

        char block[MAX_BLOCK_LEN + 1];
        memcpy(block, &text[start], block_len);
        block[block_len] = '\0';

        ESP_LOGI(TAG, "TX Block %d/%d: %s", i + 1, blocks, block);

        if (tx_ad9851_send_block((const uint8_t *)block, block_len)) {
            tx_ad9851_wait_idle();
        } else {
            ESP_LOGW(TAG, "Failed to send block, skipping");
        }

        start += block_len;

        if (i < blocks - 1) {
            vTaskDelay(pdMS_TO_TICKS(BLOCK_GAP_MS));
        }
    }

    ESP_LOGI(TAG, "All blocks sent");
}

static void tx_task(void *pvParameters)
{
    QueueHandle_t tx_queue = (QueueHandle_t)pvParameters;
    ESP_LOGI(TAG, "TX task started on core %d", xPortGetCoreID());

    while (1) {
        char *msg = NULL;
        if (xQueueReceive(tx_queue, &msg, portMAX_DELAY) == pdPASS && msg) {
            tx_send_message(msg, strlen(msg));
            free(msg);
        }
    }
}

static void console_task(void *pvParameters)
{
    QueueHandle_t tx_queue = (QueueHandle_t)pvParameters;
    ESP_LOGI(TAG, "Console task started on core %d", xPortGetCoreID());

    char *line = (char *)malloc(BUF_SIZE);
    if (!line) {
        ESP_LOGE(TAG, "FATAL: Failed to allocate console buffer!");
        vTaskDelete(NULL);
        return;
    }

    int len = 0;
    bool line_truncated = false;

    printf("\r\n[MAIN] === AFSK Transceiver Ready ===\r\n");
    printf("[MAIN] Type message and press Enter:\r\n");
    fflush(stdout);

    while (1) {
        int ch = getchar();
        if (ch == EOF) {
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }

        if (ch == '\n' || ch == '\r') {
            if (line_truncated) {
                ESP_LOGW(TAG, "Line too long (> %d bytes) — discarded, nothing sent",
                         BUF_SIZE - 1);
                len = 0;
                line_truncated = false;
                printf("[MAIN] Enter next message: \r\n");
                fflush(stdout);
                continue;
            }

            if (len > 0) {
                line[len] = '\0';

                char *msg = strdup(line);
                if (msg) {
                    if (xQueueSend(tx_queue, &msg, pdMS_TO_TICKS(100)) != pdPASS) {
                        free(msg);
                        ESP_LOGW(TAG, "TX queue full, console message dropped");
                    } else {
                        putchar('\n');
                        fflush(stdout);
                        printf("[MAIN] Enter next message: \r\n");
                        fflush(stdout);
                    }
                } else {
                    ESP_LOGE(TAG, "strdup failed for console message");
                }

                len = 0;
            }
            continue;
        }

        if (line_truncated) {
            continue;
        }

        if (len < BUF_SIZE - 1) {
            line[len++] = (char)ch;
            putchar(ch);
            fflush(stdout);
        } else {
            line_truncated = true;
        }
    }
}

static void rx_task(void *pvParameters)
{
    (void)pvParameters;
    ESP_LOGI(TAG, "RX task started on core %d", xPortGetCoreID());

    i2s_chan_handle_t rx_chan = NULL;
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_SLAVE);
    chan_cfg.dma_desc_num = 16;
    chan_cfg.dma_frame_num = 256;
    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, NULL, &rx_chan));

    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE),
        .slot_cfg = {
            .data_bit_width = (i2s_data_bit_width_t)RX_DATA_BITS,
            .slot_bit_width = (i2s_slot_bit_width_t)RX_SLOT_BITS,
            .slot_mode = I2S_SLOT_MODE_STEREO,
            .slot_mask = I2S_STD_SLOT_BOTH,
            .ws_width = RX_DATA_BITS,
            .ws_pol = false,
            .bit_shift = true,
        },
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = I2S_BCK_PIN,
            .ws = I2S_WS_PIN,
            .dout = I2S_GPIO_UNUSED,
            .din = I2S_DATA_PIN,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = false,
                .ws_inv = false,
            },
        },
    };

    ESP_LOGI(TAG, "Initializing I2S Slave...");
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(rx_chan, &std_cfg));
    ESP_ERROR_CHECK(i2s_channel_enable(rx_chan));
    ESP_LOGI(TAG, "I2S Slave enabled");

    afsk_decoder_init(&decoder, SAMPLE_RATE);

    printf("\n========================================\n");
    printf("AFSK DECODER (Quadrature + matched filter + DPLL)\n");
    printf("Sample Rate: %d Hz\n", SAMPLE_RATE);
    printf("Baud Rate: %d\n", BAUD_RATE);
    printf("Samples per bit: %d\n", SAMPLES_PER_BIT);
    printf("Mark: %d Hz | Space: %d Hz\n", MARK_FREQ, SPACE_FREQ);
    printf("Message assembled after %d ms of silence\n", MESSAGE_IDLE_MS);
    printf("========================================\n");
    printf("[RX] Waiting for AFSK signal...\n");

    int32_t *buffer = (int32_t *)heap_caps_malloc(512 * sizeof(int32_t), MALLOC_CAP_DMA);
    if (!buffer) {
        ESP_LOGE(TAG, "Failed to allocate DMA buffer");
        vTaskDelete(NULL);
        return;
    }

    s_assembly_len = 0;
    s_assembly_blocks = 0;
    s_assembly_dropped = 0;
    s_assembling = false;
    TickType_t last_packet_tick = 0;

    uint32_t packets_received = 0;
    uint32_t crc_errors = 0;
    size_t bytes_read = 0;
    TickType_t last_stat_tick = xTaskGetTickCount();

    while (1) {
        if (s_assembling &&
            (xTaskGetTickCount() - last_packet_tick) >= pdMS_TO_TICKS(MESSAGE_IDLE_MS)) {
            s_assembly[s_assembly_len] = '\0';
            printf("\n########################################\n");
            printf("[RX] FULL MESSAGE: %d bytes in %" PRIu32 " blocks\n",
                   s_assembly_len, s_assembly_blocks);
            if (s_assembly_dropped > 0) {
                printf("[RX] WARNING: %" PRIu32 " block(s) lost (CRC error)\n",
                       s_assembly_dropped);
            }
            /* Длинное тело сообщения не печатаем в rx_task — вывод через UART
               блокирует чтение I2S и может привести к потере блоков. */
            printf("########################################\n");

            /* Генерируем id для сообщения, принятого с эфира: клиент
               ожидает кадр Remote:<id>:<text>.  Копируем ровно assembly_len
               байт, чтобы встроенный '\0' в payload не обрезал broadcast. */
            static uint32_t rx_msg_id = 0;
            char id_buf[16];
            snprintf(id_buf, sizeof(id_buf), "%lx", (unsigned long)++rx_msg_id);
            size_t id_len = strlen(id_buf);
            if (id_len + 1 + s_assembly_len < RX_ASSEMBLY_MAX + 64) {
                memcpy(s_broadcast_buf, id_buf, id_len);
                s_broadcast_buf[id_len] = ':';
                memcpy(s_broadcast_buf + id_len + 1, s_assembly, s_assembly_len);
                s_broadcast_buf[id_len + 1 + s_assembly_len] = '\0';
            } else {
                s_broadcast_buf[0] = '\0';
            }

            wifi_link_broadcast("Remote", s_broadcast_buf);

            s_assembly_len = 0;
            s_assembly_blocks = 0;
            s_assembly_dropped = 0;
            s_assembling = false;
        }

        esp_err_t ret = i2s_channel_read(rx_chan, buffer, 512 * sizeof(int32_t),
                                         &bytes_read, pdMS_TO_TICKS(100));
        if (ret != ESP_OK || bytes_read == 0) {
            TickType_t now = xTaskGetTickCount();
            if (AFSK_VERBOSE && now - last_stat_tick >= pdMS_TO_TICKS(10000)) {
                last_stat_tick = now;
                printf("[STAT] Waiting for AFSK signal...\n");
            }
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }

        int samples = bytes_read / sizeof(int32_t);

        /* The I2S link is stereo (both slots), but the microphone feeds one
         * channel only, so the decoder is fed the left slot alone: step by two
         * int32 words and drop the right one. Nothing is lost - the right slot
         * carries no signal. The shift unpacks the 24-bit sample from the
         * 32-bit slot. */
        for (int i = 0; i < samples; i += RX_SLOTS_PER_FRAME) {
            int32_t sample = buffer[i] >> RX_SAMPLE_SHIFT;

            if (afsk_decoder_process_sample(&decoder, sample, &message)) {
                packets_received++;
                if (!message.crc_valid) crc_errors++;

                printf("\n========================================\n");
                printf("[RX] Message received!\n");
                printf("[RX] Length: %d bytes\n", message.length);
                printf("[RX] CRC: %s\n", message.crc_valid ? "OK" : "FAIL");
                if (!message.crc_valid) {
                    printf("  Expected: 0x%02X, Got: 0x%02X\n",
                           message.calculated_crc, message.received_crc);
                }
                printf("[RX] --- Text ---\n");
                printf("%s\n", message.text);
                printf("========================================\n");
                printf("[RX] Stats: Packets: %" PRIu32 " | CRC errors: %" PRIu32
                       " | Frames aborted: %" PRIu32 "\n",
                       packets_received, crc_errors, decoder.frames_aborted);

                if (message.crc_valid) {
                    int space = RX_ASSEMBLY_MAX - s_assembly_len;
                    int n = (message.length < space) ? message.length : space;
                    if (n > 0) {
                        memcpy(s_assembly + s_assembly_len, message.text, n);
                        s_assembly_len += n;
                    }
                    if (n < message.length) {
                        ESP_LOGW(TAG, "Assembly buffer full, %d byte(s) dropped",
                                 message.length - n);
                    }
                    s_assembly_blocks++;
                } else {
                    s_assembly_dropped++;
                }
                s_assembling = true;
                last_packet_tick = xTaskGetTickCount();
            }
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "=== AFSK Transceiver (TX core0 / RX core1) ===");

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    /* Build the shared NCO table before any task can touch the decoder:
     * a lazy init inside rx_task would race with a second decoder user. */
    afsk_decoder_tables_init();

    tx_ad9851_init();
    wifi_link_init();

    QueueHandle_t tx_queue = wifi_link_get_tx_queue();

    xTaskCreatePinnedToCore(tx_task, "tx_task", 8192, tx_queue, 10, NULL, 0);
    /* Console goes on core 0 next to the transmitter: its getchar() poll loop
     * has no business sharing a core with the I2S receiver. */
    xTaskCreatePinnedToCore(console_task, "console_task", 4096, tx_queue, 5, NULL, 0);
    xTaskCreatePinnedToCore(rx_task, "rx_task", 8192, NULL, 10, NULL, 1);

    ESP_LOGI(TAG, "System ready. TX on Core 0, RX on Core 1");
}
