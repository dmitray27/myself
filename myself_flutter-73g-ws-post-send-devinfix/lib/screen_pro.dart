#include "wifi_link.h"

#include <stdio.h>
#include <stdbool.h>
#include <string.h>
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

// К префиксу добавляются последние два байта MAC точки доступа:
// так несколько плат рядом не дают одинаковый SSID
#define WIFI_SSID_PREFIX "AFSK-TRX-"
// Пароль точки доступа задаётся в menuconfig (AFSK Wi-Fi Access Point),
// чтобы он не лежал в исходниках и не был одинаковым на всех платах
#define WIFI_PASS       CONFIG_AFSK_AP_PASSWORD
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

static const char *TAG = "WIFI_LINK";

static QueueHandle_t s_tx_queue = NULL;
static httpd_handle_t s_http_server = NULL;
static httpd_handle_t s_ws_server = NULL;
static SemaphoreHandle_t s_ws_mutex = NULL;

// SSID точки доступа: собирается в wifi_link_init и отдаётся клиенту по /info,
// чтобы приложению не требовалось разрешение геолокации для чтения имени сети
static char s_ssid[33] = {0};

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

static void client_set_name(int fd, const char *name)
{
    xSemaphoreTake(s_ws_mutex, portMAX_DELAY);

    ws_client_t *slot = client_slot_locked(fd);
    if (slot) {
        strlcpy(slot->name, name, sizeof(slot->name));
    } else {
        ESP_LOGW(TAG, "No free name slot for fd %d", fd);
    }

    xSemaphoreGive(s_ws_mutex);
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

    free(payload);
}

// ============================
// HTTP
// ============================

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
            out[i++] = (char)((hex_val(in[1]) << 4) | hex_val(in[2]));
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
    char resp[96];
    int len = snprintf(resp, sizeof(resp), "{\"ssid\":\"%s\",\"ip\":\"%s\"}",
                       s_ssid, WIFI_AP_IP);
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
    if (!body || !text) {
        free(body);
        free(text);
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

    if (strchr(from, ':') != NULL ||
        (strnlen(from, sizeof(from)) >= 6 && strncmp(from, "System", 6) == 0)) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid 'from'");
        goto cleanup;
    }

    if (strlen(text) == 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Empty 'text'");
        goto cleanup;
    }

    if (!s_tx_queue) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "No TX queue");
        goto cleanup;
    }

    char *msg = strdup(text);
    if (!msg) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Out of memory");
        goto cleanup;
    }

    // В чат сообщение попадает только после того, как встало в очередь
    // на передачу, иначе клиент видел бы "отправлено" для того,
    // что в эфир не ушло
    if (xQueueSend(s_tx_queue, &msg, pdMS_TO_TICKS(100)) != pdPASS) {
        free(msg);
        ESP_LOGW(TAG, "TX queue full, POST message dropped");
        httpd_resp_set_status(req, "503 Service Unavailable");
        httpd_resp_set_type(req, "text/plain");
        httpd_resp_send(req, "TX queue full", HTTPD_RESP_USE_STRLEN);
        result = ESP_OK;
        goto cleanup;
    }

    wifi_link_broadcast(from, text);

    const char *resp = "OK";
    httpd_resp_set_type(req, "text/plain");
    httpd_resp_send(req, resp, strlen(resp));
    result = ESP_OK;

cleanup:
    free(body);
    free(text);
    return result;
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
        if (strlen(name) == 0 || strchr(name, ':')) {
            ESP_LOGW(TAG, "Rejected name from fd %d: '%s'", fd, name);
            ws_notify(fd, "Недопустимое имя");
            return;
        }
        client_set_name(fd, name);
        ESP_LOGI(TAG, "Client %d set name to %s", fd, name);
        return;
    }

    if (strncmp(payload, "msg:", 4) != 0) {
        return;
    }

    char *frame_name = payload + 4;
    char *colon = strchr(frame_name, ':');
    if (!colon) {
        ESP_LOGW(TAG, "Malformed msg frame, no name separator: %s", payload);
        return;
    }

    *colon = '\0';
    char *text = colon + 1;

    if (strlen(text) == 0) {
        return;
    }

    // Имя из setName: надёжнее того, что пришло в кадре
    char from[WS_NAME_MAX] = {0};
    if (!client_get_name(fd, from, sizeof(from))) {
        strlcpy(from, frame_name, sizeof(from));
    }
    if (strlen(from) == 0) {
        strlcpy(from, "Unknown", sizeof(from));
    }

    if (!s_tx_queue) {
        ws_notify(fd, "Передатчик недоступен");
        return;
    }

    char *msg = strdup(text);
    if (!msg) {
        ws_notify(fd, "Недостаточно памяти");
        return;
    }

    if (xQueueSend(s_tx_queue, &msg, pdMS_TO_TICKS(100)) != pdPASS) {
        free(msg);
        ESP_LOGW(TAG, "TX queue full, WS message dropped");
        ws_notify(fd, "Очередь передачи занята, сообщение не отправлено");
        return;
    }

    // Рассылаем всем, включая отправителя: для него это подтверждение,
    // что сообщение принято в очередь на передачу
    wifi_link_broadcast(from, text);
}

static esp_err_t ws_handler(httpd_req_t *req)
{
    if (req->method == HTTP_GET) {
        int fd = httpd_req_to_sockfd(req);
        ESP_LOGI(TAG, "WS handshake done, fd=%d", fd);
        client_register(fd);
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
            ESP_LOGI(TAG, "WS text from fd %d: %s",
                     httpd_req_to_sockfd(req), (char *)buf);
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
    config.max_uri_handlers = 5;
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

    httpd_register_uri_handler(s_http_server, &ping_uri);
    httpd_register_uri_handler(s_http_server, &info_uri);
    httpd_register_uri_handler(s_http_server, &send_uri);

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
    s_tx_queue = xQueueCreate(TX_QUEUE_LEN, sizeof(char *));
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

    wifi_config_t wifi_config = {0};
    int written = snprintf(s_ssid, sizeof(s_ssid), "%s%02X%02X",
                           WIFI_SSID_PREFIX, mac[4], mac[5]);
    size_t ssid_len = (written < 0) ? 0 : (size_t)written;
    if (ssid_len > sizeof(wifi_config.ap.ssid)) {
        ssid_len = sizeof(wifi_config.ap.ssid);
    }

    memcpy(wifi_config.ap.ssid, s_ssid, ssid_len);
    wifi_config.ap.ssid_len = ssid_len;
    strlcpy((char *)wifi_config.ap.password, WIFI_PASS,
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
}
