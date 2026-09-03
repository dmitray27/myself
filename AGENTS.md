# Заметки для агента — myself-myself_200_640

## Структура проекта

- `tx_rx_mes_200b_filter_verbose_wifi/` — прошивка ESP32 AFSK TX/RX (ESP-IDF 6.0).
- `flutter/` — Flutter-клиент, общается с ESP32 по Wi-Fi/WebSocket.
- Главная точка входа: `tx_rx_mes_200b_filter_verbose_wifi/main/main.c`.
- Ключевые модули:
  - `main/afsk_decoder.c` / `.h` — демодулятор/декодер AFSK.
  - `main/afsk_protocol.c` / `.h` — сериализация блоков и CRC.
  - `main/afsk_common.h` — общие параметры линка (скорость, преамбула, размеры блоков).
  - `main/wifi_link.c` / `.h` — WebSocket/широковещательная рассылка во Flutter.

## Сборка и прошивка

```bash
. /home/dima/.espressif/v6.0.1/esp-idf/export.sh
idf.py build
idf.py -p /dev/ttyUSB0 flash   # TX плата
idf.py -p /dev/ttyUSB1 flash   # RX плата
```

Или сразу обе платы из каталога прошивки:

```bash
cd tx_rx_mes_200b_filter_verbose_wifi
. /home/dima/.espressif/v6.0.1/esp-idf/export.sh && idf.py -p /dev/ttyUSB0 flash && idf.py -p /dev/ttyUSB1 flash
```

## Радио/серийный тест

Новый мульти-тестовый скрипт лежит в корне проекта:

```bash
cd /home/dima/DevProjectNew/myself-myself_200_640
/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_serial_test.py
```

- TX порт: `/dev/ttyUSB0`, RX порт: `/dev/ttyUSB1`, baud: `115200`.
- Отчёт пишется в `afsk_test_report.txt` (в корне проекта).
- Скрипт прогоняет: `short_ascii`, `cyr_1`, `cyr_25`, `cyr_50`, `cyr_200`, `cyr_255`, `cyr_300`, `cyr_600`.
- Чтобы запустить только один тест: `--tests cyr_600`.

Старый focused-тест на 600 символов:

```bash
/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_cyr600_test.py
```

## Важные находки

- `PREAMBLE_BITS = 640`; приёмник лочится после `PREAMBLE_DETECT = 480` (75%). В тестах синхронизация стабильная: `480/480` с уверенностью 99–100% и 0 глитчей.
- `MAX_BLOCK_LEN = 50` полезных байт на AFSK-блок. `afsk_utf8_block_len()` не разрывает многобайтовые UTF-8 символы при разбиении.
- `MAX_MESSAGE_LEN = 256` — размер текстового буфера декодера на один блок. Многоблочные сообщения собираются в отдельный `s_assembly` размером `RX_ASSEMBLY_MAX = 8192`.
- **Не выводить длинный текст из `rx_task`.** Печать тела `FULL MESSAGE` в UART блокирует `i2s_channel_read()` достаточно долго, чтобы пропустить следующий блок. Тело убрано; оставлен только заголовок `FULL MESSAGE`.
- Широковещательная рассылка в Wi-Fi делается точным `memcpy` ровно `assembly_len` байт в `s_broadcast_buf`, затем `wifi_link_broadcast("Remote", s_broadcast_buf)`. Использование `printf`/`snprintf`/`strlen` на собранном сообщении обрезает его по встроенному `\0`.
- Python `PortReader` использует инкрементальный UTF-8 декодер (`codecs.getincrementaldecoder`), чтобы не терять байты, разрезанные по границам чтения из serial-порта.

## Результаты тестов

- **AFSK серийный/радио**:
  - `cyr_300` (300 символов, 600 байт, 12 блоков): OK, 0 CRC, 0 aborted.
  - `cyr_600` (600 символов, 1200 байт, 24 блока): **OK**, 0 CRC, 0 aborted, preamble 480/480.
- **Wi-Fi / WebSocket на реальном ESP32 (AP `AFSK-TRX-8045`, `192.168.4.1`)**:
  - Python WS/HTTP тест: `Overall: OK` (HTTP `/ping`, `/send`, WS connect + echo).
  - Flutter Linux: подключение и обмен сообщениями с ESP32 OK.
  - Flutter Android (headless emulator + debug APK): приложение подключилось к ESP32, запустило foreground service и отправило имя.
- Все результаты, артефакты и команды для повторного запуска сведены в `TEST_REPORT.md`.

## Быстрый старт

- `RUN.md` — краткая инструкция по запуску всего: прошивка, AFSK, WebSocket, Linux, Android, `field_test.sh`.

## Полевые испытания

- `FIELD_TEST.md` — подробный чек-лист и команды для тестов на реальном железе.
- `field_test.sh` — автоматический прогон:
  ```bash
  ./field_test.sh
  ./field_test.sh --no-flash --skip-android
  ./field_test.sh --skip-afsk
  ```

## Wi-Fi / WebSocket тестирование

### Скрипты

- `ws_test_stub.py` — mock HTTP/WebSocket сервер + реальный клиент для платы.
  - `mock` — запускает mock-сервер на `127.0.0.1:8080/8081`.
  - `test --host 192.168.4.1` — тестирует реальную плату.
- `ws_real_hw_test.sh` — переключает Wi-Fi на AFSK-TRX, прогоняет Python + Linux тест, возвращает сеть.
- `ws_real_hw_all.sh` — то же + Android-эмулятор и APK.

### Сборка Flutter

```bash
cd flutter
flutter build linux --release
flutter build apk --debug   # для эмулятора/теста
```

### Автоматический Wi-Fi + WS + Android тест

```bash
cd /home/dima/DevProjectNew/myself-myself_200_640
./ws_real_hw_all.sh
```

Скрипт сам:
1. Сохраняет активное Wi-Fi-подключение.
2. Переподключается к `AFSK-TRX-8045` (`afsk12345`).
3. Тестирует Python WS/HTTP, Linux-бандл, Android-эмулятор.
4. Возвращает ноутбук в исходную Wi-Fi сеть.

## Протокольная деталь WebSocket

- Исходящий кадр от клиента: `msg:<имя>:<текст>` (legacy) или `msg:<имя>:<id>:<текст>` (новый).
- Плата транслирует **без** префикса `msg:`: `<имя>:<текст>` или `<имя>:<id>:<текст>`.
- `setName:<имя>` не отправляет `System:`-приветствия; реальный клиент не должен ждать его.
- Между `setName:` и первым `msg:` нужна пауза ≥ 100 мс, чтобы не упираться в `WS_MIN_MSG_INTERVAL_MS`.

## Проблемы и решения

- **AFSK `cyr_600` падал с `TX timeout`.** Причина — просело питание раций/PCM1808. После решения питания тест прошёл.
- **`UnicodeDecodeError` в `afsk_cyr600_test.py`.** Пофикшено `errors="replace"` в `codecs.getincrementaldecoder`.
- **Android APK в headless-эмуляторе не показывал Flutter-логи.** Решение — `pm grant android.permission.POST_NOTIFICATIONS` перед `am start`, чтобы не было runtime permission dialog, и debug-сборка (`flutter build apk --debug`).
- **Python WS-тест поначалу не ловил эхо.** Пофикшено: отправляем `msg:<name>:<id>:<text>`, ожидаем `<name>:<id>:<text>`; `ws_system` помечаем `NOT_EXPECTED` для реальной платы.

## Заметки по железу

- Аудио АЦП на RX — PCM1808. Если пропадает его питание, RX не принимает сигнал, в логе только тишина/idle.
- Рации/модули питаются от аккумуляторов; севшие аккумуляторы рвут AFSK-линк.
- Перед длинными тестами убедиться, что PCM1808 и рации запитаны.

## Частые команды

```bash
# Сборка прошивки
. /home/dima/.espressif/v6.0.1/esp-idf/export.sh && idf.py build

# Прошивка TX, затем RX
idf.py -p /dev/ttyUSB0 flash && idf.py -p /dev/ttyUSB1 flash

# AFSK серийный/радио тест
cd /home/dima/DevProjectNew/myself-myself_200_640
/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_serial_test.py

# Просмотр отчётов
cat afsk_test_report.txt
cat TEST_REPORT.md

# WebSocket mock-сервер
/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python ws_test_stub.py mock

# WebSocket + Linux + Android на реальном ESP32
./ws_real_hw_all.sh
```
