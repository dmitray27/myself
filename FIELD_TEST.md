# Полевой чек-лист и скрипт испытаний

> Для краткой инструкции по запуску смотри `RUN.md`.

## Цель

Проверить на реальном железе:

1. AFSK-радиоканал TX → RX с короткими и длинными кириллическими сообщениями.
2. Wi-Fi AP ESP32 + WebSocket/HTTP от Python, Linux Flutter и Android Flutter.
3. Работоспособность всего контура «радио ↔ Wi-Fi ↔ Flutter-клиенты».

## Предполёт (Pre-flight)

| # | Проверка | Ожидаемо | Что делать, если не так |
|---|----------|----------|--------------------------|
| 1 | **Питание раций/модулей** | Полностью заряжены/запитаны 5–12 В | Поставить на зарядку/заменить АКБ. Севшие АКБ рвут AFSK-линк и дают `TX timeout` / молчание RX. |
| 2 | **Питание PCM1808 (RX)** | Стабильное 3,3–5 В, микросхема не греется | Если RX молчит — сначала проверь питание АЦП. |
| 3 | **Аудиокабели** | TRS 3,5 мм или PTT-развязка надёжно подключены | Переткнуть, проверить массу. |
| 4 | **USB-UART адаптеры** | TX: `/dev/ttyUSB0`, RX: `/dev/ttyUSB1` | Переподключить, проверить `dmesg \| tty`. |
| 5 | **Микрофон/динамик рации** | TX и RX на одном частотном канале, squelch открыт | Проверить канал и уровень громкости на RX. |
| 6 | **Ноутбук с ESP-IDF и Flutter** | Среды собраны, `idf.py`, `flutter`, `adb` в PATH | Если нет — собирать заранее, в поле не тянет. |
| 7 | **Android-устройство (опционально)** | Режим разработчика, USB-отладка, `adb devices` видит | Использовать реальный телефон вместо эмулятора. |

## Подготовительные шаги

### 1. Собрать и прошить обе платы

```bash
cd /home/dima/DevProjectNew/myself-myself_200_640/tx_rx_mes_200b_filter_verbose_wifi
. /home/dima/.espressif/v6.0.1/esp-idf/export.sh
idf.py build
idf.py -p /dev/ttyUSB0 flash   # TX
idf.py -p /dev/ttyUSB1 flash   # RX
```

> Если платы уже прошиты свежей `core`, этот шаг можно пропустить.

### 2. Сверить, что обе платы в консольном режиме

Открыть два минитерминала:

```bash
miniterm /dev/ttyUSB0 115200   # TX
miniterm /dev/ttyUSB1 115200   # RX
```

Должны идти строки `I (xxxx) MAIN: ...` и `[STAT] Waiting for AFSK signal...` на RX.

## Полевой скрипт `field_test.sh`

Создан для автоматического прогона основных тестов. Запуск:

```bash
cd /home/dima/DevProjectNew/myself-myself_200_640
./field_test.sh
```

Поведение:

1. Прошивает TX и RX (`--no-flash` чтобы пропустить).
2. Запускает `afsk_serial_test.py` (`--skip-afsk` чтобы пропустить).
3. Переключает ноутбук на AP `AFSK-TRX-****` и запускает `ws_real_hw_all.sh` (`--skip-wifi` чтобы пропустить Android/эмулятор).
4. Возвращает ноутбук в исходную сеть.

Флаги:

```bash
./field_test.sh --no-flash      # не прошивать
./field_test.sh --skip-afsk     # не тестировать AFSK
./field_test.sh --skip-wifi     # не тестировать Wi-Fi/WebSocket
./field_test.sh --skip-android  # Wi-Fi, но без Android-эмулятора
```

## Ручной прогон (пошагово)

### Шаг 1: AFSK, 600 кириллических символов

```bash
cd /home/dima/DevProjectNew/myself-myself_200_640
/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_serial_test.py --tests cyr_600
```

**Ожидаемый результат:**

```text
Test cyr_600: 600 chars / 1200 bytes / 24 expected blocks
[HH:MM:SS] Sending message...
[HH:MM:SS] TX reported all blocks sent
[HH:MM:SS] TX done, waiting RX ...
[HH:MM:SS] [cyr_600] Status: OK
TX blocks: 24
RX packets: 24, CRC errors: 0, Frames aborted: 0
RX full message: 1200 bytes in 24 blocks
Preamble sync: 480/480 (100%, glitches: 0)
Report written to: afsk_test_report.txt
```

**Если `TX timeout`:**

- Проверить питание TX-рации.
- Проверить, что TX-консоль ждёт ввода (не зависла).
- Увеличить `--tx-timeout`.

**Если `RX timeout`:**

- Проверить питание PCM1808.
- Проверить аудиокабель RX.
- Проверить, что рации на одном канале.
- Поднять громкость RX.

### Шаг 2: AFSK, полный мульти-тест

```bash
/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_serial_test.py
```

Проверит `short_ascii`, `cyr_1`, `cyr_25`, `cyr_50`, `cyr_200`, `cyr_255`, `cyr_300`, `cyr_600`. Результат: `afsk_test_report.txt`.

### Шаг 3: Wi-Fi + WebSocket на реальном ESP32

```bash
./ws_real_hw_all.sh
```

**Ожидаемый результат:**

- `WebSocket/HTTP test report` → `Overall: OK`.
- Linux-бандл: `✅ Успешно подключено к ESP32`, `Отправлено имя: Linux`.
- Android-эмулятор: APK установился, `MainActivity` стартовала, `I flutter : ✅ Успешно подключено к ESP32`, `I flutter : Отправлено имя: User_xxx`.
- Сеть в конце восстановится на `Tattelecom_2529` или ту, что была до теста.

**Если Android не даёт логов:**

- Убедиться, что APK — debug, а не release: `flutter build apk --debug`.
- Проверить, что в скрипте есть `pm grant android.permission.POST_NOTIFICATIONS`.
- Для реального телефона вместо эмулятора: `adb install -t build/app/outputs/flutter-apk/app-debug.apk && adb shell am start -n com.example.radio_bridge_dual/.MainActivity`, затем `adb logcat -s flutter:I`.

### Шаг 4: Ручной тест Android на телефоне

1. На телефоне подключиться к AP `AFSK-TRX-****` / `afsk12345`.
2. Запустить приложение `radio_bridge_dual`.
3. Дождаться `✅ Успешно подключено к ESP32`.
4. Отправить несколько сообщений, проверить, что они приходят обратно (echo) и видны в чате.

**Если приложение не подключается:**

- Проверить, что телефон действительно в Wi-Fi AP платы (не в мобильном интернете).
- Проверить `adb logcat -s flutter:I` на наличие `bindToWifi` / `requestNetwork`.
- Убедиться, что нет runtime permission dialog — он заблокирует UI в headless-режиме; на телефоне просто дать разрешение.

### Шаг 5: Ручной тест Linux-десктопа

```bash
flutter/build/linux/x64/release/bundle/radio_bridge_dual
```

**Ожидаемый результат:**

- Приложение пингует `192.168.4.1`.
- WebSocket коннект, отправка `setName`, обмен сообщениями.

## Что фиксировать

После каждого теста сохраняй отчёты:

| Артефакт | Когда нужен |
|----------|-------------|
| `afsk_test_report.txt` | После `afsk_serial_test.py` |
| `afsk_cyr600_report.txt` | После `--tests cyr_600` |
| `ws_real_hw_report.txt` | После `ws_real_hw_all.sh` |
| `ws_real_hw_log.txt` | Полный лог WS + Linux + Android |
| `screenshot/logcat` телефона | Если Android вёл себя странно |

## Быстрый флегма

| Симптом | Вероятная причина | Быстрое решение |
|---------|-------------------|-----------------|
| `TX timeout` | Селая АКБ / нет питания TX | Зарядить/поменять питание |
| RX молчит | Нет питания PCM1808 | Проверить 3.3 В на PCM1808 |
| `CRC errors > 0` | Шум/низкий SNR, плохой контакт аудио | Переткнуть кабели, увеличить громкость RX, снизить шум |
| `ws_connect` FAIL | Ноутбук не в AP платы | Вручную подключиться к `AFSK-TRX-****` |
| Android: нет `I/flutter` | Runtime permission / release APK | `pm grant ... POST_NOTIFICATIONS`, собрать `--debug` |
| Linux: `ping` не проходит | Ноутбук не в AP / firewall | `nmcli`/`ip route`, отключить VPN |

## Пост-полёт

1. Вернуть ноутбук в рабочую Wi-Fi сеть (`ws_real_hw_all.sh` делает это сам).
2. Сохранить все отчёты в безопасное место (Git `core`, облако и т.д.).
3. Выключить рации, чтобы не разряжать АКБ.
4. Если находились изменения в прошивке/Flutter — закоммитить и пушнуть.

## Команды «в один блок»

```bash
cd /home/dima/DevProjectNew/myself-myself_200_640

# 1. Прошить
. /home/dima/.espressif/v6.0.1/esp-idf/export.sh
idf.py -p /dev/ttyUSB0 -C tx_rx_mes_200b_filter_verbose_wifi flash
idf.py -p /dev/ttyUSB1 -C tx_rx_mes_200b_filter_verbose_wifi flash

# 2. AFSK
/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_serial_test.py

# 3. WS + Linux + Android
./ws_real_hw_all.sh

# 4. Android-ручник на телефоне
adb install -t flutter/build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.example.radio_bridge_dual/.MainActivity
adb logcat -s flutter:I
```
