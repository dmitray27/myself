#define _GNU_SOURCE
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
/* Extended host test on top of hosttest/host_test.c.
 *
 * The committed test reinitializes the decoder for every block and feeds the
 * blocks back to back. A real link does neither: one decoder instance sees a
 * whole message, the transmitter keeps BLOCK_GAP_MS of silence between blocks
 * (plus PTT lead/tail), the receiver clock is off by a fraction of a percent
 * and there is always some noise. This test drives that path:
 *
 *   1. one persistent decoder for the whole message,
 *   2. a full-length message (573 bytes, the size that appeared on the air),
 *      split by the same afsk_utf8_block_len() the firmware uses,
 *   3. BLOCK_GAP_MS of silence between blocks, so the SIGNAL_TIMEOUT_MS
 *      finalize path and the decoder state reset run between blocks,
 *   4. sample-clock drift and noise on top,
 *   5. arithmetic checks of the block timings that TX_IDLE_TIMEOUT_MS is
 *      derived from.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

#include "afsk_protocol.h"
#include "afsk_decoder.h"

/* Symbols normally provided by tx_ad9851.c */
volatile uint32_t tx_bit_r_idx = 0;

/* Virtual clock backing the esp_timer stub */
int64_t g_virtual_us = 0;

/* Older trees keep the receiver's finalize timeout private to
 * afsk_decoder.c; mirror the value so this test also builds against them. */
#ifndef SIGNAL_TIMEOUT_MS
#define SIGNAL_TIMEOUT_MS 2000
#endif
#ifndef MAX_BLOCK_LEN
#define MAX_BLOCK_LEN 50
#endif
#ifndef BLOCK_GAP_MS
#define BLOCK_GAP_MS 500
#endif
#ifndef PTT_OVERHEAD_MS
#define PTT_OVERHEAD_MS 0
#endif
#ifndef BLOCK_BITS
#define BLOCK_BITS (PREAMBLE_BITS + (MAX_BLOCK_LEN + 1) * 10 + 10)
#endif
#ifndef TX_IDLE_TIMEOUT_MS
#define TX_IDLE_TIMEOUT_MS 5000   /* the hard-coded TIMEOUT_MS of older trees */
#endif

#define FS            48000
#define FULL_SCALE    8388608.0   /* 2^23 */
#define TONE_AMP      0.30

static bool bit_buf[16384];
static volatile uint32_t w_idx;

static int total_tests = 0, passed_tests = 0;

static void report(const char *name, bool ok, const char *fmt, ...) {
    va_list ap;
    total_tests++;
    if (ok) passed_tests++;
    printf("[%s] %-26s ", ok ? "PASS" : "FAIL", name);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
}

/* Feeds `ms` of silence (noise only) and collects any frame that finalizes. */
static void feed_silence(afsk_decoder_t *dec, afsk_message_t *msg, int ms,
                         double noise_amp, unsigned int *seed,
                         char *assembled, int *assembled_len) {
    int samples = (int)((int64_t)ms * FS / 1000);
    for (int i = 0; i < samples; i++) {
        double n = noise_amp * (((double)rand_r(seed) / RAND_MAX) * 2.0 - 1.0);
        int32_t smp = (int32_t)(n * FULL_SCALE);
        g_virtual_us += 1000000 / FS;
        if (afsk_decoder_process_sample(dec, smp, msg) && msg->crc_valid) {
            memcpy(assembled + *assembled_len, msg->text, msg->length);
            *assembled_len += msg->length;
        }
    }
}

/* One message end to end: split into blocks, key each block with a gap of
 * silence after it, reassemble what the decoder hands back. */
static bool run_message_case(const char *name, const char *message,
                             double fs_actual, double noise_amp) {
    int len = (int)strlen(message);
    char assembled[4096] = {0};
    int assembled_len = 0;
    int blocks = 0;
    unsigned int seed = 4242;

    afsk_decoder_t dec;
    afsk_message_t msg;
    memset(&msg, 0, sizeof(msg));
    g_virtual_us = 0;
    afsk_decoder_init(&dec, FS);

    int samples_per_bit_gen = (int)(fs_actual / BAUD_RATE + 0.5);
    double phase = 0.0;

    /* radio comes up: silence before the first block */
    feed_silence(&dec, &msg, 200, noise_amp, &seed, assembled, &assembled_len);

    for (int start = 0; start < len; ) {
        int block_len = afsk_utf8_block_len(message, start, len, MAX_BLOCK_LEN);
        char block[MAX_BLOCK_LEN + 1];
        memcpy(block, message + start, block_len);
        block[block_len] = '\0';
        blocks++;

        tx_bit_r_idx = 0;
        w_idx = 0;
        memset(bit_buf, 0, sizeof(bit_buf));
        afsk_serialize_block((const uint8_t *)block, block_len, bit_buf, &w_idx,
                             sizeof(bit_buf) / sizeof(bit_buf[0]));
        uint32_t nbits = w_idx;

        for (uint32_t b = 0; b < nbits; b++) {
            double f = bit_buf[b] ? (double)MARK_FREQ : (double)SPACE_FREQ;
            for (int i = 0; i < samples_per_bit_gen; i++) {
                phase += 2.0 * M_PI * f / fs_actual;
                double n = noise_amp *
                           (((double)rand_r(&seed) / RAND_MAX) * 2.0 - 1.0);
                int32_t smp = (int32_t)((TONE_AMP * sin(phase) + n) * FULL_SCALE);
                g_virtual_us += 1000000 / FS;
                if (afsk_decoder_process_sample(&dec, smp, &msg) &&
                    msg.crc_valid) {
                    memcpy(assembled + assembled_len, msg.text, msg.length);
                    assembled_len += msg.length;
                }
            }
        }

        /* the transmitter's inter-block pause, plus PTT overhead when keyed */
        feed_silence(&dec, &msg, BLOCK_GAP_MS + PTT_OVERHEAD_MS, noise_amp,
                     &seed, assembled, &assembled_len);
        start += block_len;
    }

    /* enough trailing silence for the last frame to finalize on timeout */
    feed_silence(&dec, &msg, SIGNAL_TIMEOUT_MS + 500, noise_amp, &seed,
                 assembled, &assembled_len);

    assembled[assembled_len] = '\0';
    bool ok = assembled_len == len && memcmp(assembled, message, len) == 0 &&
              dec.frames_aborted == 0;
    report(name, ok, "blocks=%d assembled=%d/%d bytes aborted=%u",
           blocks, assembled_len, len, (unsigned)dec.frames_aborted);
    if (!ok && assembled_len) {
        printf("       got: \"%.80s\"...\n", assembled);
    }
    return ok;
}

/* The timings TX_IDLE_TIMEOUT_MS is derived from must match what the
 * serializer actually keys, otherwise the transmitter is released early. */
static void run_timing_checks(void) {
    char payload[MAX_BLOCK_LEN];
    memset(payload, 'A', sizeof(payload));

    tx_bit_r_idx = 0;
    w_idx = 0;
    memset(bit_buf, 0, sizeof(bit_buf));
    afsk_serialize_block((const uint8_t *)payload, sizeof(payload), bit_buf,
                         &w_idx, sizeof(bit_buf) / sizeof(bit_buf[0]));

    report("BLOCK_BITS matches TX", w_idx == BLOCK_BITS,
           "serialized=%u BLOCK_BITS=%d", (unsigned)w_idx, BLOCK_BITS);

    int air_ms = (int)((int64_t)w_idx * 1000 / BAUD_RATE);
    report("timeout covers block",
           TX_IDLE_TIMEOUT_MS > air_ms + PTT_OVERHEAD_MS,
           "air=%d ms + ptt=%d ms < timeout=%d ms", air_ms, PTT_OVERHEAD_MS,
           TX_IDLE_TIMEOUT_MS);

    report("gap shorter than rx timeout",
           BLOCK_GAP_MS + PTT_OVERHEAD_MS < SIGNAL_TIMEOUT_MS,
           "gap=%d ms < rx timeout=%d ms", BLOCK_GAP_MS + PTT_OVERHEAD_MS,
           SIGNAL_TIMEOUT_MS);
}

int main(void) {
    /* 573 bytes: the length that showed the problem on the air. */
    static char long_msg[574];
    const char *seed_text =
        "Embedded systems combine hardware and software to work reliably. ";
    for (size_t i = 0; i < sizeof(long_msg) - 1; i++) {
        long_msg[i] = seed_text[i % strlen(seed_text)];
    }
    long_msg[sizeof(long_msg) - 1] = '\0';

    run_timing_checks();

    run_message_case("573 bytes clean", long_msg, (double)FS, 0.0);
    run_message_case("573 bytes drift+0.3%", long_msg, (double)FS * 1.003, 0.0);
    run_message_case("573 bytes drift-0.3%", long_msg, (double)FS * 0.997, 0.0);
    run_message_case("573 bytes drift+noise", long_msg, (double)FS * 1.002, 0.03);

    run_message_case("cyrillic gaps",
        "Встраиваемые системы объединяют аппаратную и программную части, "
        "поэтому проверять их приходится целиком, а не по кусочкам.",
        (double)FS, 0.0);
    run_message_case("cyrillic gaps drift", 
        "Встраиваемые системы объединяют аппаратную и программную части, "
        "поэтому проверять их приходится целиком, а не по кусочкам.",
        (double)FS * 1.002, 0.02);
    run_message_case("emoji gaps",
        "😀😃😄😁😆😅🤣😂🙂🙃😇😉😊😋😌🥰😍🤩😘😗😚😙🥲😋😛", (double)FS, 0.0);

    printf("\n=== %d/%d checks passed ===\n", passed_tests, total_tests);
    return (passed_tests == total_tests) ? 0 : 1;
}
