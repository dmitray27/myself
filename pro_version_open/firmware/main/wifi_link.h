#pragma once
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

/* Initialize Wi-Fi AP, HTTP and WebSocket servers. */
void wifi_link_init(void);

/* Element of the TX queue: the text goes on the air, the id (may be empty for
   console input) is echoed back to the clients in "status:<id>:<state>"
   frames as the message progresses. Free with tx_item_free(). */
#define TX_ITEM_ID_MAX 24

typedef struct {
    char id[TX_ITEM_ID_MAX];
    char *text;
} tx_item_t;

void tx_item_free(tx_item_t *item);

/* Get the FreeRTOS queue used to feed messages to the AFSK transmitter
   (items are tx_item_t*). */
QueueHandle_t wifi_link_get_tx_queue(void);

/* Copies text/id into a new item and queues it. false when the queue is full
   or memory is short - nothing was queued and the caller keeps ownership. */
bool wifi_link_enqueue(const char *text, const char *id, TickType_t wait);

/* Broadcast "from:<id>:text" (or legacy "from:text") to all connected
   WebSocket clients. The [text] argument may contain the id prefix. */
void wifi_link_broadcast(const char *from, const char *text);

/* Send a "System:<text>" notice to all clients without storing it in history. */
void wifi_link_notify_all(const char *text);

/* Delivery progress of an outgoing message: "status:<id>:<state>[:<detail>]"
   to all clients, not stored in history. States used by the app:
   aired (all blocks keyed), delivered (ACK from <detail> station),
   noack (no ACK within ACK_TIMEOUT_MS), failed (could not be sent). */
void wifi_link_status(const char *id, const char *state, const char *detail);

/* True if the resulting "from:id:text" (id may be NULL/empty) fits one WS frame.
   Single limit for HTTP, WS and the client (kMaxFrameBytes). */
bool wifi_link_message_fits(const char *from, const char *id, const char *text);

/* Link statistics shown by the app (channel indicator). main.c updates them
   from rx_task/tx_task; wifi_link serves them at GET /stat and pushes a
   "stat:{...}" frame to the clients whenever they change (rate limited). */
typedef struct {
    uint32_t rx_frames;      /* AFSK frames decoded (any CRC)          */
    uint32_t crc_errors;     /* frames with bad CRC                    */
    uint32_t frames_aborted; /* preamble seen, no byte decoded         */
    uint32_t rx_messages;    /* complete messages assembled            */
    uint32_t rx_incomplete;  /* messages with missing blocks           */
    uint32_t tx_messages;    /* messages keyed                         */
    uint32_t tx_acked;       /* ... confirmed by the remote station    */
    uint32_t tx_noack;       /* ... without confirmation               */
    bool rx_busy;            /* decoder inside a preamble or a frame   */
    bool tx_busy;            /* transmitter keyed                      */
    int32_t signal_db;       /* peak level over noise floor, dB (0 = unknown) */
    uint8_t preamble_pct;    /* best preamble score of the last frame, % */
} link_stats_t;

void wifi_link_stats_update(const link_stats_t *stats);

/* A station acknowledged one of our messages: remember it and push the
   "peers:<station>=<seconds ago>,..." list to the clients. */
void wifi_link_peer_seen(const char *station);

/* Station id (last two MAC bytes as hex, AFSK_STATION_LEN chars) - also the
   suffix of the default SSID. */
const char *wifi_link_station_id(void);
