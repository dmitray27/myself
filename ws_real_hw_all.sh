#!/bin/bash
set -o pipefail

LOG=/tmp/ws_real_hw_all.log
REPORT=/tmp/ws_real_hw_all_report.txt
AP="AFSK-TRX-8045"
AP_BSSID="00:4B:12:2F:80:45"
FALLBACK_AP="AFSK-TRX-C131"
FALLBACK_BSSID="14:2B:2F:C7:C1:31"
PYTHON=/home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python
TEST_SCRIPT=/home/dima/DevProjectNew/myself-myself_200_640/ws_test_stub.py
APK=/home/dima/DevProjectNew/myself-myself_200_640/flutter/build/app/outputs/flutter-apk/app-debug.apk
LINUX_BUNDLE=/home/dima/DevProjectNew/myself-myself_200_640/flutter/build/linux/x64/release/bundle
ADB=/home/dima/Android/Sdk/platform-tools/adb
EMULATOR=/home/dima/Android/Sdk/emulator/emulator

exec >> "$LOG" 2>&1

echo "=== WS real hardware + Android emulator test started: $(date) ==="
stdbuf -oL -eL true 2>/dev/null || true

# Save original active Wi-Fi connection name.
ORIGINAL=$(nmcli -t -f NAME,DEVICE,TYPE connection show --active | awk -F: '$3=="802-11-wireless"{print $1}' | head -1)
echo "Original active connection: $ORIGINAL"

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

# 1. Disable autoconnect on original and disconnect.
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
    echo "=== Test aborted: $(date) ==="
    exit 1
  fi
fi

echo "Connected to AFSK AP. Verifying reachability ..."
sleep 2
ping -c 2 -W 2 192.168.4.1 || true

# 3. Start Android emulator in the background while we run other tests.
echo "Step 3: starting Android emulator headless"
EMULATOR_PID=""
if [ -x "$EMULATOR" ]; then
  $ADB start-server 2>/dev/null || true
  $EMULATOR -avd flutter_emulator -no-window -no-snapshot -wipe-data -no-audio -no-boot-anim \
    -gpu software -memory 2048 -partition-size 1024 &
  EMULATOR_PID=$!
  echo "Emulator PID: $EMULATOR_PID"
else
  echo "Emulator binary not found at $EMULATOR"
fi

# 4. Python HTTP / WebSocket test against real ESP32.
echo "Step 4: Python WS/HTTP test on 192.168.4.1"
$PYTHON "$TEST_SCRIPT" test --host 192.168.4.1 --report "$REPORT" || true

# 5. Linux desktop application runtime smoke test.
echo "Step 5: Linux bundle runtime smoke test"
if [ -x "$LINUX_BUNDLE/radio_bridge_dual" ]; then
  if command -v Xvfb >/dev/null 2>&1; then
    echo "Xvfb found, running app headless"
    export DISPLAY=:99
    Xvfb :99 -screen 0 1024x768x24 &
    sleep 2
    timeout 25s "$LINUX_BUNDLE/radio_bridge_dual" &
    APP_PID=$!
    sleep 20
    kill $APP_PID 2>/dev/null || true
    pkill -f Xvfb 2>/dev/null || true
  else
    echo "Xvfb not installed; running app directly (it will likely ignore --help and start)"
    timeout 25s "$LINUX_BUNDLE/radio_bridge_dual" &
    APP_PID=$!
    sleep 20
    kill $APP_PID 2>/dev/null || true
  fi
else
  echo "Linux bundle not found at $LINUX_BUNDLE/radio_bridge_dual"
fi

# 6. Wait for Android emulator and test APK.
echo "Step 6: Android APK runtime smoke test"
if [ -n "$EMULATOR_PID" ] && kill -0 $EMULATOR_PID 2>/dev/null; then
  echo "Waiting for emulator to boot and adb ..."
  for i in $(seq 1 180); do
    DEVICES=$($ADB devices 2>/dev/null | grep -v "List of devices" | grep -E 'device$' | awk '{print $1}')
    if [ -n "$DEVICES" ]; then
      echo "Emulator ready: $DEVICES"
      break
    fi
    sleep 1
  done

  if [ -n "$DEVICES" ]; then
    for DEV in $DEVICES; do
      echo "Waiting for $DEV to finish booting ..."
      for i in $(seq 1 60); do
        BOOT=$($ADB -s "$DEV" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        if [ "$BOOT" = "1" ]; then
          echo "$DEV boot completed"
          break
        fi
        sleep 1
      done
      # Extra time for PackageManager and other services.
      sleep 10
      echo "Installing APK on $DEV"
      $ADB -s "$DEV" install -r -t "$APK" || true
      # Grant notification permission so the app doesn't show a runtime dialog in headless mode.
      $ADB -s "$DEV" shell pm grant com.example.radio_bridge_dual android.permission.POST_NOTIFICATIONS 2>/dev/null || true
      echo "Starting main activity on $DEV"
      $ADB -s "$DEV" logcat -c 2>/dev/null || true
      $ADB -s "$DEV" shell am start -n com.example.radio_bridge_dual/.MainActivity 2>/dev/null || true
      echo "Waiting for app to initialize ..."
      sleep 5
      PID=$($ADB -s "$DEV" shell pidof com.example.radio_bridge_dual 2>/dev/null | tr -d '\r')
      echo "App process id: ${PID:-none}"
      sleep 25
      echo "Relevant logcat from $DEV (flutter/runtime/crash):"
      $ADB -s "$DEV" logcat -d -s flutter:I AndroidRuntime:E ActivityManager:I 2>/dev/null | tail -100 || true
      echo "Full logcat dump saved to /tmp/android_logcat_${DEV}.txt"
      $ADB -s "$DEV" logcat -d 2>/dev/null | gzip > "/tmp/android_logcat_${DEV}.txt.gz"
    done
  else
    echo "Emulator did not come online, skipping APK runtime"
  fi

  echo "Stopping emulator"
  kill $EMULATOR_PID 2>/dev/null || true
  sleep 2
  kill -9 $EMULATOR_PID 2>/dev/null || true
else
  echo "Emulator not started or already dead, skipping APK runtime"
fi

# 7. Restore the original (internet) connection.
echo "Step 7: restoring original Wi-Fi"
restore_original_autoconnect
nmcli connection down "$AP" 2>/dev/null || true
nmcli connection down "$FALLBACK_AP" 2>/dev/null || true
nmcli connection up "$ORIGINAL" 2>/dev/null || nmcli device wifi rescan 2>/dev/null
wait_for_original_ip

echo "Final active connection:"
nmcli connection show --active 2>/dev/null | head -5

echo "=== WS real hardware + Android emulator test finished: $(date) ==="
