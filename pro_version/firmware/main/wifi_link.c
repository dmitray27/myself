#include "wifi_link.h"

#include <stdio.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <ctype.h>
#include <stdlib.h>
#include <unistd.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_err.h"
#include "esp_timer.h"
#include "esp_mac.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_http_server.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "nvs.h"

#include "afsk_common.h"

// К префиксу добавляются последние два байта MAC точки доступа:
// так несколько плат рядом не дают одинаковый SSID
#define WIFI_SSID_PREFIX "AFSK-TRX-"
// Пароль точки доступа по умолчанию задаётся в menuconfig (AFSK Wi-Fi Access
// Point); SSID и пароль, заданные из приложения через POST /config,
// хранятся в NVS и имеют приоритет
#define WIFI_PASS       CONFIG_AFSK_AP_PASSWORD
#define NVS_NAMESPACE   "afsk"
#define NVS_KEY_SSID    "ssid"
#define NVS_KEY_PASS    "pass"
#define WIFI_PASS_MIN   8
#define WIFI_PASS_MAX   63
#define WIFI_SSID_MAX   32
#define WIFI_CHANNEL    1
#define WIFI_MAX_STA    4
#define WIFI_INACTIVE_TIME_S 30

#define WIFI_AP_IP      "192.168.4.1"

#define TX_QUEUE_LEN    4
#define POST_BUF_SIZE   1024
#define WS_MAX_CLIENTS  4
#define WS_NAME_MAX     32

// Кадр длиннее WS_MAX_FRAME_LEN вычитывается и игнорируется: на 300 бод
// столько данных всё равно уходит в эфир десятки секунд.
// Кадр длиннее WS_HARD_MAX_LEN вычитывать не пытаемся — рвём сессию,
// иначе придётся выделять произвольный объём памяти по запросу клиента.
#define WS_MAX_FRAME_LEN 1024
#define WS_HARD_MAX_LEN  8192

// Последние сообщения хранятся на плате: клиент, у которого соединение
// оборвалось (например при засыпании телефона), получает пропущенное
// сразу после рукопожатия
// Слот вмещает любой кадр, который проходит WS_MAX_FRAME_LEN, плюс имя
#define HISTORY_SIZE    20
#define HISTORY_MAX_LEN (WS_MAX_FRAME_LEN + WS_NAME_MAX + 8)

static const char *TAG = "WIFI_LINK";

static QueueHandle_t s_tx_queue = NULL;
static httpd_handle_t s_http_server = NULL;
static httpd_handle_t s_ws_server = NULL;
static SemaphoreHandle_t s_ws_mutex = NULL;

// Кольцевой буфер разосланных сообщений в виде "from:text".
// Доступ под s_ws_mutex
static char s_history[HISTORY_SIZE][HISTORY_MAX_LEN];
static uint32_t s_history_count = 0;

// SSID точки доступа: собирается в wifi_link_init и отдаётся клиенту по /info,
// чтобы приложению не требовалось разрешение геолокации для чтения имени сети
static char s_ssid[33] = {0};
static char s_station[AFSK_STATION_LEN + 1] = {0};

// Статистика линка: пишет main.c, читает httpd. Доступ под s_ws_mutex
static link_stats_t s_stats;
static bool s_stats_dirty = false;
static esp_timer_handle_t s_stats_timer = NULL;
#define STATS_PUSH_MS   2000

// Абоненты в эфире: станции, чьи ACK мы слышали, и когда. Приложение
// получает список кадром peers:<станция>=<сек назад>,...
#define PEERS_MAX       8
#define PEER_TTL_S      900
typedef struct {
    char station[AFSK_STATION_LEN + 1];
    uint32_t last_seen_ms;
} peer_t;
static peer_t s_peers[PEERS_MAX];

// Дескриптор 0 — валидный номер сокета, поэтому пустой слот помечаем -1
#define WS_FD_NONE (-1)

typedef struct {
    int fd;
    char name[WS_NAME_MAX];
    uint32_t last_msg_ms;
} ws_client_t;

// Состояние клиентов: имя из setName: и время последнего сообщения.
// Индекс — просто слот, ищем по fd
static ws_client_t s_ws_clients[WS_MAX_CLIENTS];

static void clients_init(void)
{
    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        s_ws_clients[i].fd = WS_FD_NONE;
        s_ws_clients[i].name[0] = '\0';
        s_ws_clients[i].last_msg_ms = 0;
    }
}

QueueHandle_t wifi_link_get_tx_queue(void)
{
    return s_tx_queue;
}

const char *wifi_link_station_id(void)
{
    return s_station;
}

void tx_item_free(tx_item_t *item)
{
    if (item) {
        free(item->text);
        free(item);
    }
}

bool wifi_link_enqueue(const char *text, const char *id, TickType_t wait)
{
    if (!s_tx_queue || !text || text[0] == '\0') {
        return false;
    }
    tx_item_t *item = (tx_item_t *)calloc(1, sizeof(tx_item_t));
    if (!item) {
        return false;
    }
    item->text = strdup(text);
    if (!item->text) {
        free(item);
        return false;
    }
    if (id) {
        strlcpy(item->id, id, sizeof(item->id));
    }
    if (xQueueSend(s_tx_queue, &item, wait) != pdPASS) {
        tx_item_free(item);
        return false;
    }
    return true;
}

// ============================
// Имена клиентов
// ============================

// Слот клиента по fd; при отсутствии занимает свободный.
// Вызывать под s_ws_mutex
static ws_client_t *client_slot_locked(int fd)
{
    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        if (s_ws_clients[i].fd == fd) {
            return &s_ws_clients[i];
        }
    }
    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        if (s_ws_clients[i].fd == WS_FD_NONE) {
            s_ws_clients[i].fd = fd;
            s_ws_clients[i].name[0] = '\0';
            s_ws_clients[i].last_msg_ms = 0;
            return &s_ws_clients[i];
        }
    }
    return NULL;
}

// Слот заводится сразу после рукопожатия: троттлинг работает по слоту,
// поэтому клиент, не присылающий setName:, иначе не был бы ограничен
static void client_register(int fd)
{
    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);
    if (!client_slot_locked(fd)) {
        ESP_LOGW(TAG, "No free client slot for fd %d", fd);
    }
    xSemaphoreGive(s_ws_mutex);
}

// false, если имя уже занято другим живым клиентом этой платы
static bool client_set_name(int fd, const char *name)
{
    bool ok = true;
    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);

    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        if (s_ws_clients[i].fd != WS_FD_NONE && s_ws_clients[i].fd != fd &&
            strncmp(s_ws_clients[i].name, name, WS_NAME_MAX) == 0) {
            ok = false;
            break;
        }
    }

    if (ok) {
        ws_client_t *slot = client_slot_locked(fd);
        if (slot) {
            strlcpy(slot->name, name, sizeof(slot->name));
        } else {
            ESP_LOGW(TAG, "No free name slot for fd %d", fd);
        }
    }

    xSemaphoreGive(s_ws_mutex);
    return ok;
}

// Копирует имя клиента в out. Возвращает false, если setName: не приходил
static bool client_get_name(int fd, char *out, size_t out_size)
{
    bool found = false;

    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);
    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        if (s_ws_clients[i].fd == fd && s_ws_clients[i].name[0] != '\0') {
            strlcpy(out, s_ws_clients[i].name, out_size);
            found = true;
            break;
        }
    }
    xSemaphoreGive(s_ws_mutex);

    return found;
}

static void client_forget(int fd)
{
    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);
    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        if (s_ws_clients[i].fd == fd) {
            s_ws_clients[i].fd = WS_FD_NONE;
            s_ws_clients[i].name[0] = '\0';
            s_ws_clients[i].last_msg_ms = 0;
        }
    }
    xSemaphoreGive(s_ws_mutex);
}

#define WS_MIN_MSG_INTERVAL_MS 100

static bool client_check_rate(int fd, uint32_t now_ms)
{
    bool allowed = true;

    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);
    ws_client_t *slot = client_slot_locked(fd);
    if (slot) {
        if (slot->last_msg_ms != 0 &&
            (now_ms - slot->last_msg_ms) < WS_MIN_MSG_INTERVAL_MS) {
            allowed = false;
        } else {
            slot->last_msg_ms = now_ms;
        }
    } else {
        // Слотов нет — считаем, что клиентов и так больше, чем нужно
        allowed = false;
    }
    xSemaphoreGive(s_ws_mutex);

    return allowed;
}

// ============================
// Отправка WebSocket-кадров
// ============================

typedef struct {
    httpd_handle_t server;
    int fd;
    char *payload;
    size_t len;
} ws_send_ctx_t;

// Выполняется в задаче httpd: только так запись в сокет не пересекается
// с ответами самого сервера. Вызывать httpd_ws_send_frame_async напрямую
// из чужой задачи (например из rx_task) нельзя — кадры перемешаются
static void ws_send_work(void *arg)
{
    ws_send_ctx_t *ctx = (ws_send_ctx_t *)arg;

    httpd_ws_frame_t ws_pkt = {0};
    ws_pkt.type = HTTPD_WS_TYPE_TEXT;
    ws_pkt.payload = (uint8_t *)ctx->payload;
    ws_pkt.len = ctx->len;

    esp_err_t ret = httpd_ws_send_frame_async(ctx->server, ctx->fd, &ws_pkt);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "WS send to fd %d failed: %d", ctx->fd, ret);
        httpd_sess_trigger_close(ctx->server, ctx->fd);
    }
    free(ctx->payload);
    free(ctx);
}

static void ws_queue_text(int fd, const char *payload, size_t len)
{
    if (!s_ws_server || len == 0) {
        return;
    }

    ws_send_ctx_t *ctx = (ws_send_ctx_t *)calloc(1, sizeof(ws_send_ctx_t));
    if (!ctx) {
        return;
    }

    ctx->payload = (char *)malloc(len + 1);
    if (!ctx->payload) {
        free(ctx);
        return;
    }

    memcpy(ctx->payload, payload, len);
    ctx->payload[len] = '\0';
    ctx->server = s_ws_server;
    ctx->fd = fd;
    ctx->len = len;

    if (httpd_queue_work(s_ws_server, ws_send_work, ctx) != ESP_OK) {
        ESP_LOGW(TAG, "WS work queue full, frame to fd %d dropped", fd);
        free(ctx->payload);
        free(ctx);
    }
}

// Кадры истории отличаются префиксом "hist:": приложение показывает их
// в чате, но не проигрывает по ним звук и не показывает уведомление
static void history_send_to(int fd)
{
    // Статический: буфер больше килобайта не для стека httpd, доступ под s_ws_mutex
    static char frame[HISTORY_MAX_LEN + 8];

    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);

    uint32_t total = s_history_count;
    uint32_t start = (total > HISTORY_SIZE) ? (total - HISTORY_SIZE) : 0;
    for (uint32_t i = start; i < total; i++) {
        const char *saved = s_history[i % HISTORY_SIZE];
        if (saved[0] == '\0') {
            continue;
        }
        int len = snprintf(frame, sizeof(frame), "hist:%s", saved);
        if (len <= 5) {
            continue;
        }
        if (len > (int)sizeof(frame) - 1) {
            len = (int)sizeof(frame) - 1;
        }
        ws_queue_text(fd, frame, (size_t)len);
    }

    xSemaphoreGive(s_ws_mutex);
}

static void history_store(const char *payload)
{
    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);

    char *slot = s_history[s_history_count % HISTORY_SIZE];
    if (strlcpy(slot, payload, HISTORY_MAX_LEN) >= HISTORY_MAX_LEN) {
        // strlcpy режет по байтам: оборванная UTF-8 последовательность
        // в хвосте сломает декодирование кадра на стороне приложения
        size_t end = strlen(slot);
        size_t start = end;
        while (start > 0 && ((unsigned char)slot[start - 1] & 0xC0) == 0x80) {
            start--;
        }
        if (start > 0) {
            unsigned char lead = (unsigned char)slot[start - 1];
            if (lead & 0x80) {
                size_t need = ((lead & 0xE0) == 0xC0) ? 2 :
                              ((lead & 0xF0) == 0xE0) ? 3 :
                              ((lead & 0xF8) == 0xF0) ? 4 : 1;
                if (start - 1 + need > end) {
                    slot[start - 1] = '\0';
                }
            }
        }
    }
    s_history_count++;

    xSemaphoreGive(s_ws_mutex);
}

// Служебное уведомление одному клиенту: приложение показывает его как SnackBar
static void ws_notify(int fd, const char *text)
{
    char payload[128];
    int len = snprintf(payload, sizeof(payload), "System:%s", text);
    if (len < 0) {
        return;
    }
    if (len > (int)sizeof(payload) - 1) {
        len = (int)sizeof(payload) - 1;
    }
    ws_queue_text(fd, payload, (size_t)len);
}

static void ws_send_to_all(const char *payload, size_t payload_len);

void wifi_link_broadcast(const char *from, const char *text)
{
    if (!s_ws_server || !from || !text) {
        return;
    }

    size_t from_len = strlen(from);
    size_t text_len = strlen(text);
    if (from_len == 0 || text_len == 0) {
        return;
    }

    size_t payload_len = from_len + 1 + text_len;
    char *payload = (char *)malloc(payload_len + 1);
    if (!payload) {
        return;
    }
    memcpy(payload, from, from_len);
    payload[from_len] = ':';
    memcpy(payload + from_len + 1, text, text_len);
    payload[payload_len] = '\0';

    history_store(payload);
    ws_send_to_all(payload, payload_len);
    free(payload);
}

void wifi_link_notify_all(const char *text)
{
    if (!s_ws_server || !text || text[0] == '\0') {
        return;
    }
    char payload[160];
    int len = snprintf(payload, sizeof(payload), "System:%s", text);
    if (len < 0) {
        return;
    }
    if (len > (int)sizeof(payload) - 1) {
        len = (int)sizeof(payload) - 1;
    }
    ws_send_to_all(payload, (size_t)len);
}

void wifi_link_status(const char *id, const char *state, const char *detail)
{
    if (!s_ws_server || !id || id[0] == '\0' || !state) {
        return;
    }
    char payload[96];
    int len;
    if (detail && detail[0] != '\0') {
        len = snprintf(payload, sizeof(payload), "status:%s:%s:%s", id, state, detail);
    } else {
        len = snprintf(payload, sizeof(payload), "status:%s:%s", id, state);
    }
    if (len <= 0) {
        return;
    }
    if (len > (int)sizeof(payload) - 1) {
        len = (int)sizeof(payload) - 1;
    }
    ws_send_to_all(payload, (size_t)len);
}

// ============================
// Статистика и абоненты
// ============================

static int stats_format_locked(char *buf, size_t size)
{
    return snprintf(buf, size,
                    "{\"rx\":%" PRIu32 ",\"crc\":%" PRIu32 ",\"abort\":%" PRIu32
                    ",\"msgs\":%" PRIu32 ",\"incomplete\":%" PRIu32
                    ",\"tx\":%" PRIu32 ",\"acked\":%" PRIu32 ",\"noack\":%" PRIu32
                    ",\"rx_busy\":%s,\"tx_busy\":%s,\"signal_db\":%" PRId32
                    ",\"preamble\":%u,\"station\":\"%s\"}",
                    s_stats.rx_frames, s_stats.crc_errors, s_stats.frames_aborted,
                    s_stats.rx_messages, s_stats.rx_incomplete,
                    s_stats.tx_messages, s_stats.tx_acked, s_stats.tx_noack,
                    s_stats.rx_busy ? "true" : "false",
                    s_stats.tx_busy ? "true" : "false",
                    s_stats.signal_db, (unsigned)s_stats.preamble_pct, s_station);
}

void wifi_link_stats_update(const link_stats_t *stats)
{
    if (!s_ws_mutex || !stats) {
        return;
    }
    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);
    if (memcmp(&s_stats, stats, sizeof(s_stats)) != 0) {
        s_stats = *stats;
        s_stats_dirty = true;
    }
    xSemaphoreGive(s_ws_mutex);
}

// Раз в STATS_PUSH_MS: кадр stat:{...} всем клиентам, если что-то изменилось.
// Работает в задаче esp_timer, отправка всё равно уходит через httpd_queue_work
static void stats_timer_cb(void *arg)
{
    (void)arg;
    char payload[320];
    int len = 0;

    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);
    if (s_stats_dirty) {
        s_stats_dirty = false;
        len = snprintf(payload, sizeof(payload), "stat:");
        len += stats_format_locked(payload + len, sizeof(payload) - len);
    }
    xSemaphoreGive(s_ws_mutex);

    if (len > 5 && len < (int)sizeof(payload)) {
        ws_send_to_all(payload, (size_t)len);
    }
}

static esp_err_t stat_get_handler(httpd_req_t *req)
{
    char resp[320];
    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);
    int len = stats_format_locked(resp, sizeof(resp));
    xSemaphoreGive(s_ws_mutex);
    if (len <= 0 || len >= (int)sizeof(resp)) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Format error");
        return ESP_FAIL;
    }
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, resp, len);
    return ESP_OK;
}

// Список станций с возрастом последнего ACK в секундах: peers:8045=12,1A2B=340
static int peers_format_locked(char *buf, size_t size, uint32_t now_ms)
{
    int len = snprintf(buf, size, "peers:");
    bool first = true;
    for (int i = 0; i < PEERS_MAX; i++) {
        if (s_peers[i].station[0] == '\0') {
            continue;
        }
        uint32_t age_s = (now_ms - s_peers[i].last_seen_ms) / 1000;
        if (age_s > PEER_TTL_S) {
            s_peers[i].station[0] = '\0';
            continue;
        }
        int n = snprintf(buf + len, size - len, "%s%s=%" PRIu32,
                         first ? "" : ",", s_peers[i].station, age_s);
        if (n < 0 || len + n >= (int)size) {
            break;
        }
        len += n;
        first = false;
    }
    return len;
}

void wifi_link_peer_seen(const char *station)
{
    if (!s_ws_mutex || !station || station[0] == '\0') {
        return;
    }
    uint32_t now_ms = (uint32_t)(esp_timer_get_time() / 1000);
    char payload[16 + PEERS_MAX * (AFSK_STATION_LEN + 12)];

    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);
    peer_t *slot = NULL, *oldest = &s_peers[0];
    for (int i = 0; i < PEERS_MAX; i++) {
        if (strcmp(s_peers[i].station, station) == 0) {
            slot = &s_peers[i];
            break;
        }
        if (s_peers[i].station[0] == '\0') {
            if (!slot) slot = &s_peers[i];
        } else if ((int32_t)(s_peers[i].last_seen_ms - oldest->last_seen_ms) < 0) {
            oldest = &s_peers[i];
        }
    }
    if (!slot) {
        slot = oldest;
    }
    strlcpy(slot->station, station, sizeof(slot->station));
    slot->last_seen_ms = now_ms;
    int len = peers_format_locked(payload, sizeof(payload), now_ms);
    xSemaphoreGive(s_ws_mutex);

    if (len > 6) {
        ws_send_to_all(payload, (size_t)len);
    }
}

static void peers_send_to(int fd)
{
    char payload[16 + PEERS_MAX * (AFSK_STATION_LEN + 12)];
    uint32_t now_ms = (uint32_t)(esp_timer_get_time() / 1000);
    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);
    int len = peers_format_locked(payload, sizeof(payload), now_ms);
    xSemaphoreGive(s_ws_mutex);
    if (len > 6) {
        ws_queue_text(fd, payload, (size_t)len);
    }
}

bool wifi_link_message_fits(const char *from, const char *id, const char *text)
{
    /* Тот же лимит считает клиент (messageFitsFrame в chat_protocol.dart) */
    size_t len = strlen(from) + 1 + strlen(text);
    if (id && id[0] != '\0') {
        len += strlen(id) + 1;
    }
    return len <= WS_MAX_FRAME_LEN;
}

static void ws_send_to_all(const char *payload, size_t payload_len)
{
    size_t client_count = WS_MAX_CLIENTS;
    int client_fds[WS_MAX_CLIENTS];
    if (httpd_get_client_list(s_ws_server, &client_count, client_fds) == ESP_OK) {
        for (size_t i = 0; i < client_count; i++) {
#ifdef CONFIG_HTTPD_WS_SUPPORT
            // В списке есть и сокеты, не прошедшие рукопожатие
            if (httpd_ws_get_fd_info(s_ws_server, client_fds[i]) !=
                HTTPD_WS_CLIENT_WEBSOCKET) {
                continue;
            }
#endif
            ws_queue_text(client_fds[i], payload, payload_len);
        }
    }
}

// ============================
// HTTP
// ============================

/* id клиента — только латиница/цифры (та же проверка в flutter/lib/chat_protocol.dart);
   иначе сегмент — начало legacy-текста с двоеточием внутри */
static bool looks_like_id(const char *s, size_t len)
{
    if (len == 0 || len > 32) {
        return false;
    }
    for (size_t i = 0; i < len; i++) {
        if (!isalnum((unsigned char)s[i])) {
            return false;
        }
    }
    return true;
}

// Имя без ':' (разделитель кадра) и не совпадающее с префиксами служебных
// кадров (System, status, stat, peers, hist, ping/pong): иначе клиент смог
// бы подделать служебные уведомления. Та же проверка в chat_protocol.dart
static bool name_is_valid(const char *name)
{
    if (name[0] == '\0' || strchr(name, ':') != NULL) {
        return false;
    }
    if (strncmp(name, "System", 6) == 0) {
        return false;
    }
    static const char *reserved[] = {"status", "stat", "peers", "hist", "ping", "pong"};
    for (size_t i = 0; i < sizeof(reserved) / sizeof(reserved[0]); i++) {
        if (strcmp(name, reserved[i]) == 0) {
            return false;
        }
    }
    return true;
}

static int hex_val(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static void url_decode(char *out, size_t out_size, const char *in, const char *end)
{
    size_t i = 0;
    while (i < out_size - 1 && in && *in && in < end) {
        if (*in == '+') {
            out[i++] = ' ';
        } else if (*in == '%' && (in + 2) < end &&
                   hex_val(in[1]) >= 0 && hex_val(in[2]) >= 0) {
            char decoded = (char)((hex_val(in[1]) << 4) | hex_val(in[2]));
            // Встроенный '\0' обрезал бы текст при strlen ниже
            if (decoded != '\0') {
                out[i++] = decoded;
            }
            in += 2;
        } else {
            out[i++] = *in;
        }
        in++;
    }
    out[i] = '\0';
}

// Ищет значение параметра key ("from=") в теле формы. Совпадение считается
// только в начале тела или после '&', иначе "myfrom=" сойдёт за "from="
static char *find_param(char *body, const char *key)
{
    size_t klen = strlen(key);
    for (char *p = strstr(body, key); p; p = strstr(p + 1, key)) {
        if (p == body || p[-1] == '&') {
            return p + klen;
        }
    }
    return NULL;
}

static esp_err_t ping_get_handler(httpd_req_t *req)
{
    const char *resp = "pong";
    httpd_resp_set_type(req, "text/plain");
    httpd_resp_send(req, resp, strlen(resp));
    return ESP_OK;
}

// Имя сети и адрес устройства: приложение показывает SSID, полученный отсюда
static esp_err_t info_get_handler(httpd_req_t *req)
{
    char resp[160];
    int len = snprintf(resp, sizeof(resp),
                       "{\"ssid\":\"%s\",\"ip\":\"%s\",\"station\":\"%s\","
                       "\"version\":\"pro-1\"}",
                       s_ssid, WIFI_AP_IP, s_station);
    if (len < 0) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Format error");
        return ESP_FAIL;
    }
    if (len > (int)sizeof(resp) - 1) {
        len = (int)sizeof(resp) - 1;
    }

    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, resp, len);
    return ESP_OK;
}

static esp_err_t send_post_handler(httpd_req_t *req)
{
    if (req->content_len == 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Empty body");
        return ESP_FAIL;
    }

    // Раньше длинное тело молча обрезалось и клиент получал 200 OK
    // на текст, который в эфир уходил не целиком
    if (req->content_len > POST_BUF_SIZE - 1) {
        ESP_LOGW(TAG, "POST body of %d bytes rejected", (int)req->content_len);
        // httpd_err_code_t не содержит 413, поэтому статус ставим строкой
        httpd_resp_set_status(req, "413 Payload Too Large");
        httpd_resp_set_type(req, "text/plain");
        httpd_resp_sendstr(req, "Body too large");
        return ESP_FAIL;
    }

    size_t body_len = req->content_len;

    esp_err_t result = ESP_FAIL;
    char from[64] = {0};

    // Оба буфера в куче: стек задачи httpd всего несколько килобайт
    char *body = (char *)malloc(POST_BUF_SIZE);
    char *text = (char *)calloc(1, POST_BUF_SIZE);
    char *id_text = (char *)malloc(POST_BUF_SIZE + 32);
    if (!body || !text || !id_text) {
        free(body);
        free(text);
        free(id_text);
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Out of memory");
        return ESP_FAIL;
    }

    int total = 0;
    while (total < (int)body_len) {
        int ret = httpd_req_recv(req, body + total, body_len - total);
        if (ret == HTTPD_SOCK_ERR_TIMEOUT) {
            continue;
        }
        if (ret <= 0) {
            break;
        }
        total += ret;
    }
    body[total] = '\0';

    char *p_from = find_param(body, "from=");
    if (!p_from) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing 'from'");
        goto cleanup;
    }

    char *p_text = find_param(body, "text=");
    if (!p_text) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing 'text'");
        goto cleanup;
    }

    const char *body_end = body + total;
    const char *p_from_end = strchr(p_from, '&');
    const char *p_text_end = strchr(p_text, '&');

    url_decode(from, sizeof(from), p_from, p_from_end ? p_from_end : body_end);
    url_decode(text, POST_BUF_SIZE, p_text, p_text_end ? p_text_end : body_end);

    if (!name_is_valid(from)) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid 'from'");
        goto cleanup;
    }

    if (strlen(text) == 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Empty 'text'");
        goto cleanup;
    }

    /* id генерируем до проверки размера: лимит считается для итогового кадра from:id:text.
       Префикс 'p' отличает id от счётчиков rx_task и клиентов: приложение
       дедуплицирует историю по id, одинаковые номера теряли бы сообщения */
    static uint32_t post_id = 0;
    char id_buf[16];
    snprintf(id_buf, sizeof(id_buf), "p%lx", (unsigned long)++post_id);

    if (!wifi_link_message_fits(from, id_buf, text)) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Message too long");
        goto cleanup;
    }

    if (!s_tx_queue) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "No TX queue");
        goto cleanup;
    }

    // В чат сообщение попадает только после того, как встало в очередь
    // на передачу, иначе клиент видел бы "отправлено" для того,
    // что в эфир не ушло
    if (!wifi_link_enqueue(text, id_buf, pdMS_TO_TICKS(100))) {
        ESP_LOGW(TAG, "TX queue full, POST message dropped");
        httpd_resp_set_status(req, "503 Service Unavailable");
        httpd_resp_set_type(req, "text/plain");
        httpd_resp_send(req, "TX queue full", HTTPD_RESP_USE_STRLEN);
        result = ESP_OK;
        goto cleanup;
    }

    snprintf(id_text, POST_BUF_SIZE + 32, "%s:%s", id_buf, text);

    wifi_link_broadcast(from, id_text);

    // Клиенту HTTP отдаём id, чтобы он мог сопоставить status:-кадры
    httpd_resp_set_type(req, "text/plain");
    httpd_resp_send(req, id_buf, strlen(id_buf));
    result = ESP_OK;

cleanup:
    free(body);
    free(text);
    free(id_text);
    return result;
}

// ============================
// Настройка точки доступа (NVS)
// ============================

// Читает SSID/пароль из NVS. false, если сохранённых значений нет
static bool ap_config_load(char *ssid, size_t ssid_size, char *pass, size_t pass_size)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        return false;
    }
    size_t len = ssid_size;
    bool ok = nvs_get_str(h, NVS_KEY_SSID, ssid, &len) == ESP_OK && ssid[0] != '\0';
    len = pass_size;
    ok = ok && nvs_get_str(h, NVS_KEY_PASS, pass, &len) == ESP_OK &&
         strlen(pass) >= WIFI_PASS_MIN;
    nvs_close(h);
    return ok;
}

static esp_err_t ap_config_save(const char *ssid, const char *pass)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_str(h, NVS_KEY_SSID, ssid);
    if (err == ESP_OK) err = nvs_set_str(h, NVS_KEY_PASS, pass);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    return err;
}

static esp_err_t ap_config_reset(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_erase_all(h);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    return err;
}

static void restart_timer_cb(void *arg)
{
    (void)arg;
    esp_restart();
}

// Перезапуск с задержкой: ответ HTTP должен успеть уйти клиенту
static void schedule_restart(void)
{
    const esp_timer_create_args_t args = {
        .callback = restart_timer_cb,
        .name = "ap_restart",
    };
    esp_timer_handle_t t;
    if (esp_timer_create(&args, &t) == ESP_OK) {
        esp_timer_start_once(t, 1500 * 1000);
    } else {
        esp_restart();
    }
}

// GET /config -> {"ssid":"...","custom":true|false}
static esp_err_t config_get_handler(httpd_req_t *req)
{
    char ssid[WIFI_SSID_MAX + 1] = {0};
    char pass[WIFI_PASS_MAX + 1] = {0};
    bool custom = ap_config_load(ssid, sizeof(ssid), pass, sizeof(pass));
    char resp[96];
    int len = snprintf(resp, sizeof(resp), "{\"ssid\":\"%s\",\"custom\":%s}",
                       s_ssid, custom ? "true" : "false");
    if (len <= 0 || len >= (int)sizeof(resp)) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Format error");
        return ESP_FAIL;
    }
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, resp, len);
    return ESP_OK;
}

// POST /config, тело формы: ssid=<1..32 байт>&pass=<8..63 символов>
// или reset=1 (вернуть SSID по умолчанию и пароль из menuconfig).
// Ответ 200 "OK" означает: сохранено в NVS, плата перезапустится через 1.5 с
// и клиент должен подключаться к новой сети. Любая ошибка — ничего не изменено
static esp_err_t config_post_handler(httpd_req_t *req)
{
    char body[256] = {0};
    if (req->content_len == 0 || req->content_len > sizeof(body) - 1) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Bad body size");
        return ESP_FAIL;
    }
    int total = 0;
    while (total < (int)req->content_len) {
        int ret = httpd_req_recv(req, body + total, req->content_len - total);
        if (ret == HTTPD_SOCK_ERR_TIMEOUT) continue;
        if (ret <= 0) break;
        total += ret;
    }
    body[total] = '\0';
    const char *body_end = body + total;

    char *p_reset = find_param(body, "reset=");
    if (p_reset && p_reset[0] == '1') {
        esp_err_t err = ap_config_reset();
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "NVS reset failed: %s", esp_err_to_name(err));
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "NVS error");
            return ESP_FAIL;
        }
        httpd_resp_set_type(req, "text/plain");
        httpd_resp_sendstr(req, "OK");
        ESP_LOGW(TAG, "AP config reset to defaults, restarting");
        schedule_restart();
        return ESP_OK;
    }

    char *p_ssid = find_param(body, "ssid=");
    char *p_pass = find_param(body, "pass=");
    if (!p_ssid || !p_pass) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing 'ssid' or 'pass'");
        return ESP_FAIL;
    }

    char ssid[WIFI_SSID_MAX + 2] = {0};
    char pass[WIFI_PASS_MAX + 2] = {0};
    const char *ssid_end = strchr(p_ssid, '&');
    const char *pass_end = strchr(p_pass, '&');
    url_decode(ssid, sizeof(ssid), p_ssid, ssid_end ? ssid_end : body_end);
    url_decode(pass, sizeof(pass), p_pass, pass_end ? pass_end : body_end);

    size_t ssid_len = strlen(ssid);
    size_t pass_len = strlen(pass);
    if (ssid_len == 0 || ssid_len > WIFI_SSID_MAX || strchr(ssid, '"')) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "SSID must be 1..32 bytes");
        return ESP_FAIL;
    }
    if (pass_len < WIFI_PASS_MIN || pass_len > WIFI_PASS_MAX) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Password must be 8..63 characters");
        return ESP_FAIL;
    }

    esp_err_t err = ap_config_save(ssid, pass);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS save failed: %s", esp_err_to_name(err));
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "NVS error");
        return ESP_FAIL;
    }

    // Проверяем чтением: ответ OK только за то, что реально лежит в NVS
    char check_ssid[WIFI_SSID_MAX + 1] = {0};
    char check_pass[WIFI_PASS_MAX + 1] = {0};
    if (!ap_config_load(check_ssid, sizeof(check_ssid), check_pass, sizeof(check_pass)) ||
        strcmp(check_ssid, ssid) != 0 || strcmp(check_pass, pass) != 0) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "NVS verify failed");
        return ESP_FAIL;
    }

    httpd_resp_set_type(req, "text/plain");
    httpd_resp_sendstr(req, "OK");
    ESP_LOGW(TAG, "AP config saved: SSID=%s, restarting", ssid);
    schedule_restart();
    return ESP_OK;
}

// ============================
// WebSocket
// ============================

static void ws_handle_frame(httpd_req_t *req, char *payload)
{
    int fd = httpd_req_to_sockfd(req);

    uint32_t now_ms = (uint32_t)(esp_timer_get_time() / 1000);
    if (!client_check_rate(fd, now_ms)) {
        ESP_LOGW(TAG, "WS rate limit for fd %d", fd);
        ws_notify(fd, "Слишком быстро");
        return;
    }

    if (strncmp(payload, "setName:", 8) == 0) {
        const char *name = payload + 8;
        if (!name_is_valid(name)) {
            ESP_LOGW(TAG, "Rejected name from fd %d: '%s'", fd, name);
            ws_notify(fd, "Недопустимое имя");
            return;
        }
        if (!client_set_name(fd, name)) {
            ESP_LOGW(TAG, "Name '%s' busy, rejected for fd %d", name, fd);
            ws_notify(fd, "name busy");
            return;
        }
        ESP_LOGI(TAG, "Client %d set name to %s", fd, name);
        ws_notify(fd, "name ok");
        return;
    }

    if (strncmp(payload, "msg:", 4) != 0) {
        return;
    }

    char *frame_name = payload + 4;
    char *colon1 = strchr(frame_name, ':');
    if (!colon1) {
        ESP_LOGW(TAG, "Malformed msg frame, no name separator: %s", payload);
        return;
    }

    /* Новый кадр: msg:<имя>:<id>:<текст>.
       Старый кадр msg:<имя>:<текст> (без id) оставлен для совместимости. */
    char *id_start = colon1 + 1;
    char *colon2 = strchr(id_start, ':');
    char *text;
    char *broadcast_text;

    if (colon2 && looks_like_id(id_start, (size_t)(colon2 - id_start))) {
        *colon1 = '\0';
        *colon2 = '\0';
        text = colon2 + 1;
        if (strlen(text) == 0) {
            return;
        }
        /* Восстанавливаем двоеточие между id и текстом: id_start теперь
           указывает на строку "<id>:<текст>", которую можно разослать. */
        *colon2 = ':';
        broadcast_text = id_start;
    } else {
        *colon1 = '\0';
        text = id_start;
        if (strlen(text) == 0) {
            return;
        }
        broadcast_text = text;
    }

    // Имя из setName: надёжнее того, что пришло в кадре
    char from[WS_NAME_MAX] = {0};
    if (!client_get_name(fd, from, sizeof(from))) {
        strlcpy(from, frame_name, sizeof(from));
    }
    if (!name_is_valid(from)) {
        strlcpy(from, "Unknown", sizeof(from));
    }

    // broadcast_text уже содержит "<id>:" (если был), считаем итоговый кадр
    if (!wifi_link_message_fits(from, NULL, broadcast_text)) {
        ws_notify(fd, "Сообщение слишком длинное для передачи");
        return;
    }

    if (!s_tx_queue) {
        ws_notify(fd, "Передатчик недоступен");
        return;
    }

    // id для status:-кадров: часть broadcast_text до ':' (если id был)
    char id_buf[TX_ITEM_ID_MAX] = {0};
    if (broadcast_text != text) {
        size_t id_len = (size_t)(colon2 - id_start);
        if (id_len < sizeof(id_buf)) {
            memcpy(id_buf, id_start, id_len);
        }
    }

    if (!wifi_link_enqueue(text, id_buf, pdMS_TO_TICKS(100))) {
        ESP_LOGW(TAG, "TX queue full, WS message dropped");
        ws_notify(fd, "Очередь передачи занята, сообщение не отправлено");
        return;
    }

    // Рассылаем всем, включая отправителя: для него это подтверждение,
    // что сообщение принято в очередь на передачу. Если кадр содержал id,
    // broadcast_text уже в виде "<id>:<текст>".
    wifi_link_broadcast(from, broadcast_text);
}

static esp_err_t ws_handler(httpd_req_t *req)
{
    if (req->method == HTTP_GET) {
        int fd = httpd_req_to_sockfd(req);
        ESP_LOGI(TAG, "WS handshake done, fd=%d", fd);
        client_register(fd);
        history_send_to(fd);
        peers_send_to(fd);
        return ESP_OK;
    }

    httpd_ws_frame_t ws_pkt = {0};
    ws_pkt.type = HTTPD_WS_TYPE_TEXT;

    // Первый вызов без буфера возвращает длину кадра
    esp_err_t ret = httpd_ws_recv_frame(req, &ws_pkt, 0);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "WS frame header recv failed: %d", ret);
        return ret;
    }

    if (ws_pkt.len == 0) {
        return ESP_OK;
    }

    if (ws_pkt.len > WS_HARD_MAX_LEN) {
        ESP_LOGE(TAG, "WS frame of %u bytes, closing session",
                 (unsigned)ws_pkt.len);
        return ESP_FAIL;
    }

    uint8_t *buf = (uint8_t *)calloc(1, ws_pkt.len + 1);
    if (!buf) {
        ESP_LOGE(TAG, "WS buffer alloc failed");
        return ESP_ERR_NO_MEM;
    }
    ws_pkt.payload = buf;

    // Кадр вычитываем целиком даже если он слишком длинный:
    // иначе остаток тела примется за заголовок следующего кадра
    ret = httpd_ws_recv_frame(req, &ws_pkt, ws_pkt.len);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "WS recv failed: %d", ret);
        free(buf);
        return ret;
    }

    if (ws_pkt.type == HTTPD_WS_TYPE_TEXT) {
        buf[ws_pkt.len] = '\0';

        if (ws_pkt.len > WS_MAX_FRAME_LEN) {
            ESP_LOGW(TAG, "WS frame too long (%u bytes), ignored",
                     (unsigned)ws_pkt.len);
            ws_notify(httpd_req_to_sockfd(req), "Сообщение слишком длинное");
        } else {
            // Полный кадр (до 1 КБ ≈ 90 мс UART) блокирует httpd-таск и других
            // клиентов — в тихой сборке логируем только длину и начало
            if (AFSK_VERBOSE) {
                ESP_LOGI(TAG, "WS text from fd %d (%u bytes): %s",
                         httpd_req_to_sockfd(req), (unsigned)ws_pkt.len, (char *)buf);
            } else {
                ESP_LOGD(TAG, "WS text from fd %d (%u bytes): %.64s",
                         httpd_req_to_sockfd(req), (unsigned)ws_pkt.len, (char *)buf);
            }
            ws_handle_frame(req, (char *)buf);
        }
    }

    free(buf);
    return ESP_OK;
}

// Сокет закрывает httpd, но имя клиента нужно снять самим:
// номера дескрипторов переиспользуются
static void ws_close_fn(httpd_handle_t hd, int sockfd)
{
    (void)hd;
    client_forget(sockfd);
    close(sockfd);
}

// ============================
// Wi-Fi и запуск серверов
// ============================

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data)
{
    if (event_base != WIFI_EVENT) {
        return;
    }

    if (event_id == WIFI_EVENT_AP_STACONNECTED) {
        wifi_event_ap_staconnected_t *evt = (wifi_event_ap_staconnected_t *)event_data;
        ESP_LOGI(TAG, "Station "MACSTR" connected, AID=%d", MAC2STR(evt->mac), evt->aid);
    } else if (event_id == WIFI_EVENT_AP_STADISCONNECTED) {
        wifi_event_ap_stadisconnected_t *evt = (wifi_event_ap_stadisconnected_t *)event_data;
        ESP_LOGI(TAG, "Station "MACSTR" disconnected, AID=%d", MAC2STR(evt->mac), evt->aid);
    }
}

static esp_err_t start_http_server(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = 80;
    config.keep_alive_enable   = true;  
    config.keep_alive_idle     = 3;   // сек тишины до первой probe  
    config.keep_alive_interval = 2;   // интервал между probe  
    config.keep_alive_count    = 2;   // probe до признания мёртвым (~6 с)
    config.core_id = 0;
    config.max_open_sockets = 4;
    config.max_uri_handlers = 8;
    config.lru_purge_enable = true;

    if (httpd_start(&s_http_server, &config) != ESP_OK) {
        ESP_LOGE(TAG, "HTTP server start failed");
        return ESP_FAIL;
    }

    httpd_uri_t ping_uri = {
        .uri = "/ping",
        .method = HTTP_GET,
        .handler = ping_get_handler,
        .user_ctx = NULL,
    };
    httpd_uri_t info_uri = {
        .uri = "/info",
        .method = HTTP_GET,
        .handler = info_get_handler,
        .user_ctx = NULL,
    };
    httpd_uri_t send_uri = {
        .uri = "/send",
        .method = HTTP_POST,
        .handler = send_post_handler,
        .user_ctx = NULL,
    };

    httpd_uri_t stat_uri = {
        .uri = "/stat",
        .method = HTTP_GET,
        .handler = stat_get_handler,
        .user_ctx = NULL,
    };
    httpd_uri_t config_get_uri = {
        .uri = "/config",
        .method = HTTP_GET,
        .handler = config_get_handler,
        .user_ctx = NULL,
    };
    httpd_uri_t config_post_uri = {
        .uri = "/config",
        .method = HTTP_POST,
        .handler = config_post_handler,
        .user_ctx = NULL,
    };

    httpd_register_uri_handler(s_http_server, &ping_uri);
    httpd_register_uri_handler(s_http_server, &info_uri);
    httpd_register_uri_handler(s_http_server, &send_uri);
    httpd_register_uri_handler(s_http_server, &stat_uri);
    httpd_register_uri_handler(s_http_server, &config_get_uri);
    httpd_register_uri_handler(s_http_server, &config_post_uri);

    ESP_LOGI(TAG, "HTTP server started on port 80 (Core 0)");
    return ESP_OK;
}

static esp_err_t start_ws_server(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = 81;
    config.keep_alive_enable   = true;  
    config.keep_alive_idle     = 3;  
    config.keep_alive_interval = 2;  
    config.keep_alive_count    = 2;
    config.ctrl_port = 32769;
    config.core_id = 0;
    config.max_open_sockets = WS_MAX_CLIENTS;
    config.max_uri_handlers = 2;
    config.lru_purge_enable = true;
    config.close_fn = ws_close_fn;

    if (httpd_start(&s_ws_server, &config) != ESP_OK) {
        ESP_LOGE(TAG, "WS server start failed");
        return ESP_FAIL;
    }

    httpd_uri_t ws_uri = {
        .uri = "/",
        .method = HTTP_GET,
        .handler = ws_handler,
        .user_ctx = NULL,
#ifdef CONFIG_HTTPD_WS_SUPPORT
        .is_websocket = true,
        .handle_ws_control_frames = false,
#endif
    };

    httpd_register_uri_handler(s_ws_server, &ws_uri);

    ESP_LOGI(TAG, "WS server started on port 81 (Core 0)");
    return ESP_OK;
}

void wifi_link_init(void)
{
    s_tx_queue = xQueueCreate(TX_QUEUE_LEN, sizeof(tx_item_t *));
    if (!s_tx_queue) {
        ESP_LOGE(TAG, "Failed to create TX queue");
        return;
    }

    s_ws_mutex = xSemaphoreCreateMutex();
    if (!s_ws_mutex) {
        ESP_LOGE(TAG, "Failed to create WS mutex");
        return;
    }

    clients_init();

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    esp_netif_create_default_wifi_ap();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT,
                                                         ESP_EVENT_ANY_ID,
                                                         &wifi_event_handler,
                                                         NULL, NULL));

    uint8_t mac[6] = {0};
    ESP_ERROR_CHECK(esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP));

    snprintf(s_station, sizeof(s_station), "%02X%02X", mac[4], mac[5]);

    wifi_config_t wifi_config = {0};
    char pass[WIFI_PASS_MAX + 1] = {0};
    if (ap_config_load(s_ssid, sizeof(s_ssid), pass, sizeof(pass))) {
        ESP_LOGI(TAG, "AP config from NVS");
    } else {
        snprintf(s_ssid, sizeof(s_ssid), "%s%s", WIFI_SSID_PREFIX, s_station);
        strlcpy(pass, WIFI_PASS, sizeof(pass));
    }
    size_t ssid_len = strlen(s_ssid);
    if (ssid_len > sizeof(wifi_config.ap.ssid)) {
        ssid_len = sizeof(wifi_config.ap.ssid);
    }

    memcpy(wifi_config.ap.ssid, s_ssid, ssid_len);
    wifi_config.ap.ssid_len = ssid_len;
    strlcpy((char *)wifi_config.ap.password, pass,
            sizeof(wifi_config.ap.password));
    wifi_config.ap.channel = WIFI_CHANNEL;
    wifi_config.ap.max_connection = WIFI_MAX_STA;
    wifi_config.ap.authmode = WIFI_AUTH_WPA2_PSK;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_ERROR_CHECK(esp_wifi_set_inactive_time(WIFI_IF_AP, WIFI_INACTIVE_TIME_S));

    ESP_LOGI(TAG, "Wi-Fi AP started: SSID=%s, IP=" WIFI_AP_IP, s_ssid);

    if (start_http_server() != ESP_OK) {
        ESP_LOGE(TAG, "HTTP server failed to start");
    }
    if (start_ws_server() != ESP_OK) {
        ESP_LOGE(TAG, "WS server failed to start");
    }

    const esp_timer_create_args_t stats_args = {
        .callback = stats_timer_cb,
        .name = "link_stats",
    };
    if (esp_timer_create(&stats_args, &s_stats_timer) == ESP_OK) {
        esp_timer_start_periodic(s_stats_timer, (uint64_t)STATS_PUSH_MS * 1000);
    }
}
