#!/bin/bash
set -o pipefail

LOG=/tmp/ws_real_hw_test.log
REPORT=/tmp/ws_real_hw_test_report.txt
AP="AFSK-TRX-8045"
AP_BSSID="00:4B:12:2F:80:45"
FALLBACK_AP="AFSK-TRX-C131"
FALLBACK_BSSID="14:2B:2F:C7:C1:31"
PYTHON=/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python
TEST_SCRIPT=/home/dima/DevProjectNew/myself-myself_200_640/ws_test_stub.py
APK=/home/dima/DevProjectNew/myself-myself_200_640/flutter/build/app/outputs/flutter-apk/app-release.apk
LINUX_BUNDLE=/home/dima/DevProjectNew/myself-myself_200_640/flutter/build/linux/x64/release/bundle
ADB=/home/dima/Android/Sdk/platform-tools/adb

exec >> "$LOG" 2>&1

echo "=== WS real hardware test started: $(date) ==="

# Make sure all output is flushed as early as possible.
stdbuf -oL -eL true 2>/dev/null || true

# Save original active Wi-Fi connection name and autoconnect status.
ORIGINAL=$(nmcli -t -f NAME,DEVICE,TYPE connection show --active | awk -F: '$3=="802-11-wireless"{print $1}' | head -1)
echo "Original active connection: $ORIGINAL"
if [ -n "$ORIGINAL" ]; then
  ORIG_AUTO=$(nmcli -t -f connection.autoconnect connection show "$ORIGINAL" 2>/dev/null)
  echo "Original autoconnect: $ORIG_AUTO"
fi

# Helper: wait for an IP in the AFSK subnet.
wait_for_ap_ip() {
  local tries=$1
  for i in $(seq 1 "$tries"); do
    if ip addr show wlp4s0 2>/dev/null | grep -q '192\.168\.4\.'; then
      echo "AFSK IP obtained: $(ip addr show wlp4s0 | grep '192\.168\.4\.' | head -1 | awk '{print $2}')"
      return 0
    fi
    sleep 1
  done
  return 1
}

# Helper: wait for the original (internet) network to return.
wait_for_original_ip() {
  for i in $(seq 1 30); do
    if ip addr show wlp4s0 2>/dev/null | grep -qE '192\.168\.1\.|172\.16\.|10\.'; then
      echo "Original IP restored: $(ip addr show wlp4s0 | grep -E 'inet ' | head -1 | awk '{print $2}')"
      return 0
    fi
    sleep 1
  done
  return 1
}

# Helper: disable autoconnect on original connection so it doesn't steal the interface back.
disable_original_autoconnect() {
  if [ -n "$ORIGINAL" ]; then
    nmcli connection modify "$ORIGINAL" connection.autoconnect no 2>/dev/null || true
    nmcli connection modify "$ORIGINAL" connection.autoconnect-priority -100 2>/dev/null || true
  fi
}

restore_original_autoconnect() {
  if [ -n "$ORIGINAL" ]; then
    nmcli connection modify "$ORIGINAL" connection.autoconnect yes 2>/dev/null || true
    nmcli connection modify "$ORIGINAL" connection.autoconnect-priority 0 2>/dev/null || true
  fi
}

# Helper: connect to a given AFSK AP.
connect_ap() {
  local ssid=$1
  local bssid=$2
  echo "Rescanning and trying to connect to $ssid ($bssid) ..."
  nmcli device wifi rescan 2>/dev/null || true
  sleep 2
  if nmcli connection show "$ssid" >/dev/null 2>&1; then
    nmcli connection modify "$ssid" 802-11-wireless.bssid "$bssid" wifi-sec.psk "afsk12345" 2>/dev/null || true
  else
    nmcli connection add type wifi con-name "$ssid" ifname wlp4s0 ssid "$ssid" bssid "$bssid" \
      802-11-wireless.mode infrastructure wifi-sec.key-mgmt wpa-psk wifi-sec.psk "afsk12345" 2>/dev/null || true
  fi
  nmcli connection up "$ssid" 2>/dev/null
  wait_for_ap_ip 30
}

# 1. Prepare: bring down current connection and disable its autoconnect.
echo "Step 1: disabling original autoconnect and disconnecting $ORIGINAL"
disable_original_autoconnect
nmcli connection down "$ORIGINAL" 2>/dev/null || nmcli device disconnect wlp4s0 2>/dev/null || true
sleep 1

# 2. Connect to AFSK AP.
echo "Step 2: connecting to AFSK AP"
if ! connect_ap "$AP" "$AP_BSSID"; then
  echo "Primary AP failed, trying fallback $FALLBACK_AP"
  if ! connect_ap "$FALLBACK_AP" "$FALLBACK_BSSID"; then
    echo "ERROR: Could not connect to any AFSK AP. Restoring original network."
    restore_original_autoconnect
    nmcli connection up "$ORIGINAL" 2>/dev/null
    wait_for_original_ip
    echo "=== WS real hardware test aborted: $(date) ==="
    exit 1
  fi
fi

echo "Connected to AFSK AP. Verifying reachability ..."
# Give the DHCP lease and route a moment.
sleep 2
ping -c 2 -W 2 192.168.4.1 || true

# 3. Python HTTP / WebSocket test against the real ESP32.
echo "Step 3: Python WS/HTTP test on 192.168.4.1"
$PYTHON "$TEST_SCRIPT" test --host 192.168.4.1 --report "$REPORT" || true

# 4. Linux desktop application runtime smoke test.
echo "Step 4: Linux bundle runtime smoke test"
if [ -x "$LINUX_BUNDLE/radio_bridge_dual" ]; then
  if command -v Xvfb >/dev/null 2>&1; then
    echo "Xvfb found, running app headless"
    export DISPLAY=:99
    Xvfb :99 -screen 0 1024x768x24 &
    sleep 2
    timeout 20s "$LINUX_BUNDLE/radio_bridge_dual" &
    APP_PID=$!
    sleep 15
    kill $APP_PID 2>/dev/null || true
    pkill -f Xvfb 2>/dev/null || true
  else
    echo "Xvfb not installed; checking binary can start and parse args"
    "$LINUX_BUNDLE/radio_bridge_dual" --help 2>&1 || true
  fi
else
  echo "Linux bundle not found at $LINUX_BUNDLE/radio_bridge_dual"
fi

# 5. Android APK runtime smoke test.
echo "Step 5: Android APK runtime smoke test"
if [ -x "$ADB" ]; then
  DEVICES=$($ADB devices | grep -v "List of devices" | grep -E 'device$' | awk '{print $1}')
  if [ -n "$DEVICES" ]; then
    for DEV in $DEVICES; do
      echo "Installing APK on $DEV"
      $ADB -s "$DEV" install -r -t "$APK" || true
      echo "Starting main activity on $DEV"
      $ADB -s "$DEV" shell am start -n com.example.radio_bridge_dual/.MainActivity 2>/dev/null || true
      sleep 15
      echo "Relevant logcat from $DEV:"
      $ADB -s "$DEV" logcat -d -t '01-01 00:00:00.000' 2>/dev/null | grep -iE 'radio_bridge|flutter|chatconnection|websocket|esp32|network' | tail -80 || true
    done
  else
    echo "No Android devices/emulators attached, skipping APK runtime"
  fi
else
  echo "adb not found at $ADB, skipping APK runtime"
fi

# 6. Restore the original (internet) connection.
echo "Step 6: restoring original Wi-Fi"
restore_original_autoconnect
nmcli connection down "$AP" 2>/dev/null || true
nmcli connection down "$FALLBACK_AP" 2>/dev/null || true
nmcli connection up "$ORIGINAL" 2>/dev/null || nmcli device wifi rescan 2>/dev/null
wait_for_original_ip

# Show final state.
echo "Final active connection:"
nmcli connection show --active 2>/dev/null | head -5

echo "=== WS real hardware test finished: $(date) ==="
