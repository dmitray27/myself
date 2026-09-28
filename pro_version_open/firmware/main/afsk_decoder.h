#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "afsk_common.h"

#define MAX_MESSAGE_LEN     256

/* Matched-filter length: the I/Q products are integrated over one bit. */
#define MF_TAPS             (SAMPLE_RATE / BAUD_RATE)

typedef struct {
    int samples_per_bit;
} afsk_decoder_config_t;

typedef enum {
    WAITING_FOR_PREAMBLE,
    WAITING_FOR_START,
    RECEIVING,
    WAITING_FOR_NEXT_BYTE
} afsk_decoder_state_t;

typedef struct {
    char text[MAX_MESSAGE_LEN];
    uint8_t length;
    bool crc_valid;
    uint8_t received_crc;
    uint8_t calculated_crc;
} afsk_message_t;

typedef struct {
    afsk_decoder_state_t state;
    int bit_counter;
    int ones_count;
    int start_wait;
    int start_dropout;       /* consecutive unusable bits while awaiting START */
    int preamble_glitches;   /* bad bits seen in the current preamble          */
    int preamble_best;       /* highest preamble score reached, for diagnostics */
    uint32_t frames_aborted; /* frames lost before a byte was ever decoded     */
    uint8_t current_byte;
    uint8_t rx_buffer[MAX_MESSAGE_LEN];
    uint8_t rx_index;
    uint32_t last_signal_time;
    afsk_decoder_config_t config;

    /* Quadrature (I/Q) tone correlators. A complex NCO per tone is mixed with
     * the input; each product is integrated over exactly one bit period (a
     * matched filter for a tone burst of one bit), giving a per-sample power
     * estimate for each tone. mf_hist keeps one bit of history as groups of
     * four (mark I, mark Q, space I, space Q), so the running sums update in
     * O(1) per sample. */
    uint32_t phase_mark, phase_space;   /* NCO phase accumulators   */
    uint32_t inc_mark, inc_space;       /* NCO phase increments     */
    int   mf_idx;                       /* oldest slot in mf_hist   */
    float mf_hist[MF_TAPS][4];          /* one bit of I/Q products  */
    float mf_sum[4];                    /* running sums of mf_hist  */
    float mI, mQ;                       /* integrated mark I/Q      */
    float sI, sQ;                       /* integrated space I/Q     */

    /* Digital PLL for bit-clock recovery. The clock accumulator wraps once
     * per bit; the data bit is sampled at mid-bit, and every mark<->space
     * transition nudges the clock phase so sampling stays centered even if
     * the RX sample rate drifts relative to the TX bit rate. */
    uint32_t pll;
    uint32_t pll_step;
    uint32_t sample_point;   /* clock phase at which the bit is sampled */
    bool prev_sign;
    bool have_prev_sign;

    float noise_floor;
    float signal_threshold;

    /* Input level tracking: DC blocker state and the peaks reported on the
     * idle line, used to tell a real transmission from a stray carrier. */
    float dc_level;
    float peak_level;
    float peak_mark, peak_space;
    uint32_t level_report_time;
} afsk_decoder_t;

/* Builds the NCO table shared by all decoders. Call once at startup, before
 * the tasks that use a decoder are created. */
void afsk_decoder_tables_init(void);

void afsk_decoder_init(afsk_decoder_t *dec, int sample_rate);
bool afsk_decoder_process_sample(afsk_decoder_t *dec,
                                 int32_t sample,
                                 afsk_message_t *msg);
