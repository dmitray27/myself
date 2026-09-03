#!/usr/bin/env bash
# Полевой прогон: AFSK + Wi-Fi/WebSocket на реальном ESP32.
# По умолчанию прошивает платы, гоняет afsk_serial_test.py, ws_real_hw_all.sh.
set -euo pipefail

PROJECT_DIR="/home/dima/DevProjectNew/myself-myself_200_640"
FIRMWARE_DIR="$PROJECT_DIR/tx_rx_mes_200b_filter_verbose_wifi"
ESP_IDF="/home/dima/.espressif/v6.0.1/esp-idf/export.sh"
PYTHON="/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python"

TX_PORT="/dev/ttyUSB0"
RX_PORT="/dev/ttyUSB1"

DO_FLASH=true
DO_AFSK=true
DO_WIFI=true
DO_ANDROID=true

usage() {
  cat <<EOF
Использование: $(basename "$0") [опции]

Опции:
  --no-flash        Не прошивать платы
  --skip-afsk       Не запускать AFSK-тесты
  --skip-wifi       Не запускать Wi-Fi/WebSocket-тесты
  --skip-android    Запустить Wi-Fi, но без Android-эмулятора
  --tx-port PORT    Порт TX (по умолчанию /dev/ttyUSB0)
  --rx-port PORT    Порт RX (по умолчанию /dev/ttyUSB1)
  -h, --help        Эта справка

Пример:
  $(basename "$0") --skip-afsk                 # только WS + Linux + Android
  $(basename "$0") --skip-android              # AFSK + WS + Linux
  $(basename "$0") --no-flash --skip-wifi      # только AFSK, без прошивки
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-flash) DO_FLASH=false ; shift ;;
    --skip-afsk) DO_AFSK=false ; shift ;;
    --skip-wifi) DO_WIFI=false ; shift ;;
    --skip-android) DO_ANDROID=false ; shift ;;
    --tx-port) TX_PORT="$2"; shift 2 ;;
    --rx-port) RX_PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage; exit 1 ;;
  esac
done

cd "$PROJECT_DIR"

# --- Flash -------------------------------------------------------------------
if $DO_FLASH; then
  echo "=== Step 1: flashing TX and RX boards ==="
  . "$ESP_IDF"
  idf.py -C "$FIRMWARE_DIR" -p "$TX_PORT" flash
  idf.py -C "$FIRMWARE_DIR" -p "$RX_PORT" flash
  echo "Flashing done."
fi

# --- AFSK --------------------------------------------------------------------
if $DO_AFSK; then
  echo "=== Step 2: AFSK serial/radio tests ==="
  "$PYTHON" afsk_serial_test.py --tx-port "$TX_PORT" --rx-port "$RX_PORT" --report afsk_test_report.txt
  echo "AFSK test report: $PROJECT_DIR/afsk_test_report.txt"
fi

# --- Wi-Fi / WebSocket -------------------------------------------------------
if $DO_WIFI; then
  echo "=== Step 3: Wi-Fi + WebSocket tests (Python, Linux, Android) ==="
  if $DO_ANDROID; then
    ./ws_real_hw_all.sh
  else
    ./ws_real_hw_test.sh
  fi
  echo "WS test report: $PROJECT_DIR/ws_real_hw_report.txt"
fi

echo ""
echo "=== Field test finished ==="
echo "Reports:"
$DO_AFSK  && echo "  - afsk_test_report.txt"
$DO_WIFI  && echo "  - ws_real_hw_report.txt"
$DO_WIFI  && echo "  - ws_real_hw_log.txt"
echo "Check the output above for any FAIL or timeout."
