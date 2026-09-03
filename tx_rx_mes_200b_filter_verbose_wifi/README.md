# AFSK Transceiver для ESP32

Прошивка `73g_tx_rx_mes_300b_filter_verbose_wifi` — AFSK модем/трансивер на базе ESP32.

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
- `from` не может содержать `:` и не может начинаться с `System`.
- При переполнении очереди передачи возвращается `503 Service Unavailable`.

### WebSocket (порт 81)

URI: `ws://192.168.4.1/`

Команды:

```text
setName:<имя>
msg:<имя>:<текст>
```

Пример:

```text
setName:Operator
msg:Operator:Hello world
```

Логика имени:

- Если сначала выполнить `setName`, оно будет использоваться для всех последующих `msg`.
- Имя не должно содержать `:`.
- Каждому WebSocket-клиенту присваивается `fd`; rate limiting: не чаще одного сообщения в 100 мс с одного `fd`.

Максимальная длина WebSocket-кадра: `WS_MAX_FRAME_LEN = 1024` байта.

---

## Сообщения и протокол

- Сообщения передаются в UTF-8.
- Длинные сообщения автоматически разбиваются на блоки по 50 байт так, чтобы не резать многобайтовые UTF-8 символы.
- Каждый блок защищён CRC-8.
- RX собирает блоки в сообщение, если пауза между ними меньше `MESSAGE_IDLE_MS`.

---

## Ограничения

- Serial-консоль: до **8191 байт** на одно сообщение.
- HTTP/WS: до **~1 КБ** на запрос/кадр.
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
| `main/wifi_link.c` | Wi-Fi AP, HTTP и WebSocket серверы |
| `main/main.c` | FreeRTOS задачи TX, RX и UART-консоли |
| `sdkconfig.defaults` | Пины для ESP32-WROOM |
| `sdkconfig.defaults.esp32s3` | Пины для ESP32-S3 |
