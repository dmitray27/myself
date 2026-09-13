# AFSK Transceiver для ESP32

Прошивка `tx_rx_mes_200b_filter_verbose_wifi` — AFSK модем/трансивер на базе ESP32.
Клиент для телефона/ПК — Flutter-приложение в `../flutter` (см. его README).

Передача: AD9851 DDS (1200/2200 Гц, 200 бод).  
Приём: I2S ADC (PCM1808 или аналог) с квадратурным демодулятором, matched filter и DPLL.

Поддерживаемые платы: **ESP32-WROOM** (target `esp32`) и **ESP32-S3** (target `esp32s3`).

---

## Что умеет прошивка

- Передавать текстовые сообщения в эфир в виде AFSK-сигнала.
- Принимать AFSK-сигнал с рации и декодировать его.
- Работать как Wi-Fi точка доступа (`AFSK-TRX-xxxx`) с HTTP и WebSocket API.
- Принимать сообщения через UART-консоль (удобно для отладки без Wi-Fi).
- Разбивать длинные сообщения на блоки по 50 байт полезной нагрузки (с CRC-8 в каждом блоке).

---

## Аппаратное подключение

### Общая схема

```
ESP32 (TX + AD9851) → рация TX → эфир → рация RX → ESP32 (RX + PCM1808)
```

Один и тот же бинарник работает и как TX, и как RX: роль определяется подключённым периферийным железом.

### Пины ESP32-WROOM (по умолчанию, `sdkconfig.defaults`)

| Функция | GPIO | Примечание |
|---|---|---|
| AD9851 FQ_UD | 18 | frequency update |
| AD9851 W_CLK | 19 | word clock |
| AD9851 DATA  | 21 | serial data |
| AD9851 RESET | 16 | reset |
| PTT (рация)  | 15 | opto-isolator / MOSFET вместо кнопки PTT |
| I2S BCK      | 26 | bit clock от ADC |
| I2S WS       | 25 | word select / LRCK |
| I2S DATA     | 22 | аудио-сэмплы от ADC |

### Пины ESP32-S3 (`sdkconfig.defaults.esp32s3`)

| Функция | GPIO | Примечание |
|---|---|---|
| AD9851 FQ_UD | 18 | frequency update |
| AD9851 W_CLK | 4  | word clock (GPIO19 занят native USB) |
| AD9851 DATA  | 21 | serial data |
| AD9851 RESET | 16 | reset |
| PTT (рация)  | 15 | opto-isolator / MOSFET |
| I2S BCK      | 5  | bit clock |
| I2S WS       | 6  | word select |
| I2S DATA     | 7  | аудио-сэмплы |

Пины можно изменить через `idf.py menuconfig` → **AFSK Pin Configuration**.

---

## Сборка и прошивка

Требуется **ESP-IDF v5.x-v6.x** (тестировалось на v6.0.1).

```bash
cd tx_rx_mes_200b_filter_verbose_wifi
. /path/to/esp-idf/export.sh

# Для ESP32-WROOM:
idf.py set-target esp32
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor

# Для ESP32-S3:
# idf.py set-target esp32s3
# idf.py build
# idf.py -p /dev/ttyUSB0 flash monitor
```

При смене target конфигурация пинов подтянется автоматически из `sdkconfig.defaults.esp32s3`.

### Два профиля логирования

| Профиль | Что в UART | Когда |
|---|---|---|
| **verbose** (по умолчанию) | преамбула, уровни, каждый RX-блок с текстом и `Stats`, TX-блоки с текстом, полные WS-кадры | отладка, стенд, `afsk_serial_test.py` |
| **release** | CRC FAIL, заголовки собранных сообщений, номер/длина TX-блока, Wi-Fi события | поле, боевой комплект |

Оба собираются из одного дерева в разные каталоги, не мешая друг другу:

```bash
# verbose — обычная сборка (build/, sdkconfig)
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor

# release — отдельный build-каталог и отдельный sdkconfig
idf.py -B build_release -DSDKCONFIG=sdkconfig.release \
    -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.release" build
idf.py -B build_release -p /dev/ttyUSB0 flash monitor

# release для ESP32-S3
idf.py -B build_release_s3 -DIDF_TARGET=esp32s3 -DSDKCONFIG=sdkconfig.release.s3 \
    -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.esp32s3;sdkconfig.defaults.release" build
```

Переключатель — `idf.py menuconfig` → **AFSK Logging** → *Verbose diagnostics*
(`CONFIG_AFSK_VERBOSE_LOG`). Подробности — в разделе «Логирование и производительность».

---

## Параметры радиоканала

| Параметр | Значение |
|---|---|
| Mark (логическая 1) | 1200 Гц |
| Space (логический 0) | 2200 Гц |
| Baud rate | 200 бод |
| I2S sample rate | 48000 Гц |
| Preamble | 640 бит |
| Полезная нагрузка блока | 50 байт |
| CRC | CRC-8 (poly 0x07, init 0x00) |
| PTT lead | 300 мс |
| PTT tail | 100 мс |
| Пауза между блоками | 500 мс |

---

## Использование через UART

После старта в консоли появится приглашение:

```
[MAIN] === AFSK Transceiver Ready ===
[MAIN] Type message and press Enter:
```

Введите текст и нажмите Enter — сообщение разобьётся на блоки и уйдёт в эфир.

Максимальная длина сообщения через UART: **8191 байт** (`BUF_SIZE - 1`).

---

## Wi-Fi API

Каждая плата поднимает точку доступа:

- **SSID**: `AFSK-TRX-xxxx` (последние 2 байта MAC)
- **IP**: `192.168.4.1`
- **Пароль по умолчанию**: `afsk12345` (меняется в `menuconfig` → **AFSK Wi-Fi Access Point**)

### HTTP (порт 80)

| Метод | Endpoint | Описание |
|---|---|---|
| GET | `/ping` | Ответ `pong` |
| GET | `/info` | JSON: `{"ssid":"AFSK-TRX-xxxx","ip":"192.168.4.1"}` |
| POST | `/send` | Отправить сообщение в эфир. Тело: `from=<имя>&text=<сообщение>` |

Пример:

```bash
curl -d "from=Operator&text=Hello" http://192.168.4.1/send
```

Ограничения `/send`:

- Максимальный размер тела: `POST_BUF_SIZE - 1` (~1023 байта).
- `from` не пустое, без `:` и не начинается с `System`.
- `%00` в теле отбрасывается.
- При переполнении очереди передачи возвращается `503 Service Unavailable`.

Принятое сообщение рассылается WebSocket-клиентам как `<from>:p<n>:<text>`
(`p` — префикс счётчика HTTP-сообщений).

### WebSocket (порт 81)

URI: `ws://192.168.4.1:81/`

Кадры от клиента:

```text
setName:<имя>
msg:<имя>:<id>:<текст>      # новый формат, id генерирует клиент
msg:<имя>:<текст>           # legacy без id
```

Кадры от платы (всем подключённым клиентам, включая отправителя — это эхо-подтверждение):

```text
<имя>:<id>:<текст>          # сообщение клиента, ушедшее в очередь TX
Remote:r<n>:<текст>         # сообщение, принятое с эфира
hist:<имя>:<id>:<текст>     # история после рукопожатия
System:<текст>              # служебное уведомление (этому клиенту или всем, в историю не попадает)
```

Пример:

```text
setName:Operator
msg:Operator:k3f9a1:Hello world
→ Operator:k3f9a1:Hello world
```

Правила:

- Имя из `setName` используется для всех последующих `msg`; иначе берётся имя из кадра.
- Имя не пустое, без `:` и не начинается с `System` (защита от подделки служебных сообщений); иначе `Unknown`.
- Между `setName:` и первым `msg:` нужна пауза ≥ 100 мс: rate limit — одно сообщение в `WS_MIN_MSG_INTERVAL_MS = 100` мс на клиента.
- Одновременно до `WS_MAX_CLIENTS = 4` клиентов.
- Максимальная длина кадра: `WS_MAX_FRAME_LEN = 1024` байта; кадры длиннее `WS_HARD_MAX_LEN = 8192` закрывают соединение.
- Тот же лимит проверяется для итогового кадра `<имя>:<id>:<текст>` (`wifi_link_message_fits`) и для WS, и для HTTP `/send`: WS-клиент получает `System:Сообщение слишком длинное для передачи`, HTTP — `400 Message too long`. Клиент считает то же в `messageFitsFrame()`.
- Сообщение с эфира, в котором хотя бы один блок не прошёл CRC, в чат не рассылается — вместо него всем клиентам уходит `System:Сообщение из эфира принято с ошибками (потеряно блоков: N)`.

### Идентификаторы сообщений

Счётчики независимы, поэтому id имеют префикс источника: `p<hex>` — HTTP `/send`,
`r<hex>` — принято с эфира, клиентские id — как прислал клиент. Счётчики
сбрасываются при перезагрузке платы; клиент дедуплицирует историю по паре
(отправитель, id).

### История

Плата хранит последние `HISTORY_SIZE = 20` разосланных кадров и досылает их
новому клиенту сразу после рукопожатия с префиксом `hist:`. Слот истории
вмещает любой кадр, прошедший `WS_MAX_FRAME_LEN`; более длинное (например
AFSK-сообщение) обрезается по границе UTF-8 символа.

---

## Сообщения и протокол

- Сообщения передаются в UTF-8.
- Длинные сообщения автоматически разбиваются на блоки по 50 байт так, чтобы не резать многобайтовые UTF-8 символы.
- Каждый блок защищён CRC-8.
- RX собирает блоки в сообщение, если пауза между ними меньше `MESSAGE_IDLE_MS`
  (1.5 × `BLOCK_TIME_MS`); буфер сборки `RX_ASSEMBLY_MAX = 8192` байт.
- Собранное сообщение уходит в Wi-Fi как `Remote:r<n>:<текст>` ровно с длиной сборки
  (без `strlen`, чтобы встроенный `\0` не обрезал текст). Если хотя бы один блок
  потерян по CRC, сообщение не рассылается — только `System:`-уведомление о потере.
- Обе стороны печатают CRC32 (zlib-совместимый, `esp_rom_crc32_le`) всего сообщения:
  TX — в `Message: N bytes, Blocks: B, CRC32: XXXXXXXX`, RX — в `FULL MESSAGE: ... CRC32: XXXXXXXX`.
  `afsk_serial_test.py` сравнивает RX CRC32 с `zlib.crc32` отправленного текста — проверка
  содержимого без печати тела из `rx_task`.

---

## Логирование и производительность

UART 115200 бод ≈ 11.5 КБ/с, вывод блокирующий. DMA-буфер I2S
(16 × 256 кадров @ 48 кГц) даёт ~85 мс запаса — печать дольше этого в `rx_task`
теряет входные сэмплы.

| Что | Где | Стоимость | Управление |
|---|---|---|---|
| Заголовок `FULL MESSAGE` (байты, блоки, CRC32 без тела) | `rx_task` | ~5 мс на сообщение | всегда |
| По-блочная диагностика RX (`Message received`, `Stats`) | `rx_task` | ~25 мс на 50-байтный блок (~1 % от 2.5 с эфира) | `AFSK_VERBOSE` |
| `[PREAMBLE] n/480`, `[RX] Frame aborted` | декодер | ~4 мс раз в ~300 мс | `AFSK_VERBOSE` |
| `[LEVEL]` уровни сигнала | декодер | раз в 5 с | `LEVEL_REPORT_MS` |
| `TX Block i/n: <len> bytes[: <текст>]` | `tx_task` | 5–10 мс, вне битового цикла | текст — `AFSK_VERBOSE` |
| `WS text from fd` | httpd | verbose: весь кадр, до ~90 мс; тихая: длина + 64 байта на `ESP_LOGD` | `AFSK_VERBOSE` |

`AFSK_VERBOSE` берётся из menuconfig → **AFSK Logging** (`CONFIG_AFSK_VERBOSE_LOG`,
по умолчанию включено); флаг компилятора `-DAFSK_VERBOSE=0/1` имеет приоритет.
Тестовые скрипты `afsk_serial_test.py` / `afsk_cyr600_test.py` разбирают строки
`FULL MESSAGE`, `Stats:` и `[PREAMBLE]`, поэтому гонять их нужно на verbose-сборке.
**Никогда не печатайте тело сообщения целиком из `rx_task`** — это не включается
даже в verbose-профиле.

---

## Ограничения

- Serial-консоль: до **8191 байт** на одно сообщение.
- HTTP/WS: до **~1 КБ** на запрос/кадр; история — последние 20 кадров.
- Один процесс печати в `rx_task` не должен превышать ~85 мс (см. «Логирование»).
- Время передачи одного блока 50 байт: примерно 6.7 с (с учётом preamble, PTT и межблочной паузы).
- Для полноценного сквозного теста `TX → эфир → RX` через Wi-Fi обычно нужны два клиентских устройства, так как каждая плата — отдельная AP.

---

## Полезные команды

```bash
# Пересборка после изменений
idf.py fullclean
idf.py set-target esp32
idf.py build

# Только прошивка
idf.py -p /dev/ttyUSB0 flash

# Монитор
idf.py -p /dev/ttyUSB0 monitor
```

---

## Файлы проекта

| Файл | Назначение |
|---|---|
| `main/afsk_common.h` | Общие параметры AFSK (частоты, baud rate, тайминги) |
| `main/afsk_protocol.c` | Разбиение UTF-8 сообщений на блоки, CRC-8 |
| `main/afsk_decoder.c` | Демодулятор: quadrature + matched filter + DPLL |
| `main/tx_ad9851.c` | Управление DDS AD9851 и PTT |
| `main/wifi_link.c` | Wi-Fi AP, HTTP и WebSocket серверы, история сообщений |
| `main/main.c` | FreeRTOS задачи TX, RX и UART-консоли |
| `sdkconfig.defaults` | Пины для ESP32-WROOM |
| `sdkconfig.defaults.esp32s3` | Пины для ESP32-S3 |
