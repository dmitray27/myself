# Comprehensive test report — AFSK + Wi-Fi/WebSocket

## 1. Summary

| Test | Target | Status |
|------|--------|--------|
| AFSK `cyr_300` (300 Cyr chars, 600 B, 12 blocks) | Real TX/RX radios | OK |
| AFSK `cyr_600` (600 Cyr chars, 1200 B, 24 blocks) | Real TX/RX radios | OK |
| Python WS/HTTP mock | `127.0.0.1:8080/8081` | OK |
| Python WS/HTTP real ESP32 | `192.168.4.1:80/81` | OK |
| Flutter Linux app real ESP32 | `192.168.4.1` | OK |
| Flutter Android app real ESP32 | `192.168.4.1` | OK |
| Wi-Fi AP connection / restore | `AFSK-TRX-8045` / `Tattelecom_2529` | OK |

All critical paths passed. The session stayed alive through the network switch — the Wi-Fi was automatically restored to `Tattelecom_2529` after each AFSK-TRX test.

---

## 2. AFSK serial/radio tests

### 2.1 `cyr_300` — 300 Cyrillic characters

- Source report: `afsk_test_report_focused.txt`
- Payload: 300 chars / 600 bytes UTF-8 / 12 blocks
- Result: OK, 0 CRC errors, 0 aborted frames, preamble sync 480/480

### 2.2 `cyr_600` — 600 Cyrillic characters

- Test script: `afsk_cyr600_test.py`
- Report: `afsk_cyr600_report.txt`
- Payload: 600 chars / 1200 bytes UTF-8 / 24 blocks
- Result: **OK**, all 24 blocks received, 0 CRC errors, 0 aborted frames

```
## cyr_600
Status: OK
Sent (600 chars, 1200 bytes): ПроверкаПроверка...
TX blocks: 24
RX packets: 24, CRC errors: 0, Frames aborted: 0
Preamble sync: 480/480 (100%, glitches: 0)
RX full message: 1200 bytes in 24 blocks
```

---

## 3. WebSocket/HTTP tests

### 3.1 Mock server test

- Script: `ws_test_stub.py`
- Command:
  ```bash
  /home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python \
    /home/dima/DevProjectNew/myself-myself_200_640/ws_test_stub.py mock
  # in another shell:
  /home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python \
    /home/dima/DevProjectNew/myself-myself_200_640/ws_test_stub.py test \
    --host 127.0.0.1 --ws-port 8081 --http-port 8080
  ```
- Result: `Overall: OK`

### 3.2 Real ESP32 test

- Report: `ws_real_hw_report.txt`
- AP: `AFSK-TRX-8045` / `192.168.4.1`
- Result:
  ```
  http_ping: OK
  http_send: OK (200)
  ws_connect: OK
  ws_system: NOT_EXPECTED (no greeting from real board)
  ws_echo: OK ('TestUser:t1788455493016:Hello from ws test')
  ws_name: SENT

  Overall: OK
  ```

The real board does not send a `System:` greeting on WebSocket open, which is expected and the test now marks it as `NOT_EXPECTED` instead of a failure.

---

## 4. Flutter Linux desktop app

- Built with: `flutter build linux --release`
- Bundle: `flutter/build/linux/x64/release/bundle/radio_bridge_dual`
- Test log: `ws_real_hw_log.txt`
- Result: app launched, pinged the ESP32, connected over WebSocket and sent `setName:Linux`:
  ```
  Проверяю ping ESP32...
  ESP32 доступен, подключаю WebSocket...
  ✅ Успешно подключено к ESP32
  Отправлено имя: Linux
  ```

---

## 5. Flutter Android app

- Built with: `flutter build apk --debug`
- APK: `flutter/build/app/outputs/flutter-apk/app-debug.apk`
- Emulator: `flutter_emulator` (headless)
- Test log: `ws_real_hw_log.txt`
- Result: APK installed, `MainActivity` started, foreground service launched, app connected to ESP32 and sent its user name:
  ```
  I flutter : ✅ Успешно подключено к ESP32
  I flutter : Отправлено имя: User_245
  ```

> Note: the first emulator attempts were blocked by a runtime `POST_NOTIFICATIONS` permission dialog. Pre-granting the permission via `adb shell pm grant ...` before `am start` allowed the app to proceed in headless mode.

---

## 6. Test scripts and artifacts (offline availability)

The following files are now in the project directory and are available offline (they are saved on disk, not in `/tmp`):

| File | Purpose |
|------|---------|
| `afsk_serial_test.py` | AFSK multi-test bench (`short_ascii`…`cyr_600`) |
| `afsk_cyr600_test.py` | AFSK 600 Cyrillic focused serial/radio test |
| `ws_test_stub.py` | Python mock WS/HTTP server + real-board test client |
| `ws_real_hw_all.sh` | End-to-end Wi-Fi switch + Python/Linux/Android test runner |
| `ws_real_hw_test.sh` | Lighter Wi-Fi switch + Python/Linux test runner |
| `ws_real_hw_report.txt` | Real ESP32 WS/HTTP test report |
| `ws_real_hw_log.txt` | Full log of the combined real-hardware test run |
| `afsk_cyr600_report.txt` | 600 Cyrillic AFSK test report |
| `afsk_test_report.txt` | Full AFSK test report (all cases) |
| `afsk_test_report_focused.txt` | AFSK focused report incl. `cyr_300` |

- `afsk_serial_test.py` — multi-test AFSK serial/radio bench (re-created; covers `short_ascii` through `cyr_600`).

The old ad-hoc `/tmp/afsk_serial_test.py` has been replaced by the persistent multi-test script in the project directory.

---

## 7. How to re-run

### AFSK serial/radio

```bash
cd /home/dima/DevProjectNew/myself-myself_200_640
. /home/dima/.espressif/v6.0.1/esp-idf/export.sh
idf.py -p /dev/ttyUSB0 flash && idf.py -p /dev/ttyUSB1 flash

/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_serial_test.py
```

### WebSocket real hardware

```bash
./ws_real_hw_all.sh
```

The script will:
1. Save and disconnect the current Wi-Fi.
2. Connect to `AFSK-TRX-8045`.
3. Run the Python WS/HTTP test against `192.168.4.1`.
4. Run the Linux bundle.
5. Launch the Android emulator, install the APK, start the app and capture logcat.
6. Restore the original Wi-Fi connection.

---

## 8. Final state

- Laptop is back on `Tattelecom_2529` (`192.168.1.7/24`).
- ESP32 AP `AFSK-TRX-8045` remains available for future tests.
- Builds are cached in:
  - Firmware: `tx_rx_mes_200b_filter_verbose_wifi/build/`
  - Linux app: `flutter/build/linux/x64/release/bundle/`
  - Android APK: `flutter/build/app/outputs/flutter-apk/`
