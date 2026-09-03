# Как запускать — быстрая инструкция

Все команды выполняются из корня проекта:

```bash
cd /home/dima/DevProjectNew/myself-myself_200_640
```

## 1. Прошивка ESP32 (TX и RX)

```bash
cd tx_rx_mes_200b_filter_verbose_wifi
. /home/dima/.espressif/v6.0.1/esp-idf/export.sh
idf.py build
idf.py -p /dev/ttyUSB0 flash   # TX
idf.py -p /dev/ttyUSB1 flash   # RX
```

> Порты могут отличаться. Проверь `ls /dev/ttyUSB*`.

## 2. AFSK serial/radio тест

```bash
/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_serial_test.py
```

Все тесты: `short_ascii`, `cyr_1`, `cyr_25`, `cyr_50`, `cyr_200`, `cyr_255`, `cyr_300`, `cyr_600`.

Только `cyr_600`:

```bash
/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_serial_test.py --tests cyr_600
```

Другие порты:

```bash
/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_serial_test.py --tx-port /dev/ttyUSB2 --rx-port /dev/ttyUSB3
```

Результат: `afsk_test_report.txt`.

## 3. Wi-Fi + WebSocket + Linux + Android

```bash
./ws_real_hw_all.sh
```

Что делает:
- сохраняет текущее Wi-Fi-подключение;
- подключается к `AFSK-TRX-****` / `afsk12345`;
- тестирует Python WS/HTTP;
- запускает Linux-версию приложения;
- поднимает Android-эмулятор с APK и смотрит логи;
- возвращает ноутбук в исходную сеть.

**Без Android-эмулятора**:

```bash
./ws_real_hw_test.sh
```

## 4. Полевой прогон «одной командой»

```bash
./field_test.sh
```

Флаги:

| Флаг | Значение |
|------|----------|
| `--no-flash` | Не прошивать платы |
| `--skip-afsk` | Пропустить AFSK-тесты |
| `--skip-wifi` | Пропустить Wi-Fi/WebSocket |
| `--skip-android` | Wi-Fi, но без Android-эмулятора |
| `--tx-port PORT` | Порт TX (по умолчанию `/dev/ttyUSB0`) |
| `--rx-port PORT` | Порт RX (по умолчанию `/dev/ttyUSB1`) |

Примеры:

```bash
./field_test.sh --no-flash                # прошивка уже залита
./field_test.sh --skip-android            # только AFSK + Wi-Fi + Linux
./field_test.sh --skip-afsk --no-flash    # только Wi-Fi + Linux + Android
```

## 5. Сборка Flutter

Если APK/Linux-бандл устарели:

```bash
cd flutter
flutter build linux --release
flutter build apk --debug   # для тестов/эмулятора
```

## 6. Ручной Android-запуск

```bash
adb install -t flutter/build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.example.radio_bridge_dual/.MainActivity
adb logcat -s flutter:I
```

## Быстрый старт после прошивки

```bash
cd /home/dima/DevProjectNew/myself-myself_200_640
/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_serial_test.py
./ws_real_hw_all.sh
```
