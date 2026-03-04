#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] run.sh (Plan A stable unzip + socat + mono-with-tty) starting"

OPTIONS_JSON="/data/options.json"

get_opt() {
  local key="$1"
  local def="${2:-}"
  local val=""
  if command -v jq >/dev/null 2>&1; then
    val="$(jq -r --arg k "$key" '.[$k] // empty' "$OPTIONS_JSON" 2>/dev/null || true)"
    if [ -n "$val" ] && [ "$val" != "null" ]; then
      echo "$val"
      return
    fi
  fi
  echo "$def"
}

use_socat="$(get_opt use_socat "true")"
waveshare_host="$(get_opt waveshare_host "")"
waveshare_port="$(get_opt waveshare_port "0")"
serial_port="$(get_opt serial_port "/tmp/comfobox")"
baudrate="$(get_opt baudrate "38400")"

mqtt_host="$(get_opt mqtt_host "core-mosquitto")"
mqtt_port="$(get_opt mqtt_port "1883")"
mqtt_user="$(get_opt mqtt_user "")"
mqtt_pass="$(get_opt mqtt_pass "")"

mqtt_base_topic="$(get_opt mqtt_base_topic "ComfoBox")"
bacnet_master_id="$(get_opt bacnet_master_id "1")"
bacnet_client_id="$(get_opt bacnet_client_id "3")"

echo "[INFO] waveshare=${waveshare_host}:${waveshare_port}"
echo "[INFO] serial=${serial_port} baud=${baudrate}"
echo "[INFO] mqtt=${mqtt_host}:${mqtt_port}"
echo "[INFO] mqtt_base_topic=${mqtt_base_topic}"
echo "[INFO] bacnet_master_id=${bacnet_master_id} bacnet_client_id=${bacnet_client_id}"

ZIP="/app/ComfoBox2Mqtt_0.4.0.zip"
if [ ! -f "$ZIP" ]; then
  echo "[ERROR] ZIP not found at $ZIP"
  exit 1
fi

echo "[INFO] Cleaning previous RF77 folder"
rm -rf /app/rf77
mkdir -p /app/rf77

echo "[INFO] Unzipping RF77 package"
unzip -o "$ZIP" -d /app/rf77 >/dev/null

echo "[DEBUG] Listing extracted content:"
find /app/rf77 -maxdepth 3 -type f -name "*.exe" -print || true

EXE_PATH="$(find /app/rf77 -type f -name "ComfoBoxMqttConsole.exe" | head -n1 || true)"
if [ -z "$EXE_PATH" ]; then
  echo "[ERROR] ComfoBoxMqttConsole.exe not found after unzip"
  find /app/rf77 -maxdepth 6 -print || true
  exit 1
fi

APPDIR="$(dirname "$EXE_PATH")"
CFG="${EXE_PATH}.config"

echo "[INFO] RF77 detected at: $APPDIR"
echo "[INFO] Config file: $CFG"

# --- socat TCP->PTY (Waveshare) ---
if [ "$use_socat" = "true" ]; then
  if [ -z "$waveshare_host" ] || [ "$waveshare_port" = "0" ]; then
    echo "[ERROR] socat enabled but waveshare not configured"
    exit 1
  fi

  echo "[INFO] Starting socat (TCP->PTY)..."
  socat \
    "PTY,link=${serial_port},rawer,echo=0,waitslave" \
    "TCP:${waveshare_host}:${waveshare_port}" &
  SOCAT_BRIDGE_PID="$!"

  # give PTY time to appear
  sleep 1
  ls -la "$serial_port" || true
else
  SOCAT_BRIDGE_PID=""
fi

# --- minimal config patch (keep it simple & deterministic) ---
if [ -f "$CFG" ]; then
  echo "[INFO] Patching config"

  # These are the actual defaults in RF77 config you pasted:
  # Baudrate=76800, Port=COM8, MqttBrokerAddress=localhost, BacnetMasterId=1, BacnetClientId=3, BaseTopic=ComfoBox
  sed -i "s|<value>localhost</value>|<value>${mqtt_host}</value>|g" "$CFG" || true
  sed -i "s|<value>COM8</value>|<value>${serial_port}</value>|g" "$CFG" || true
  sed -i "s|<value>76800</value>|<value>${baudrate}</value>|g" "$CFG" || true
  sed -i "s|<value>ComfoBox</value>|<value>${mqtt_base_topic}</value>|g" "$CFG" || true
  sed -i "s|<value>1</value>|<value>${bacnet_master_id}</value>|g" "$CFG" || true
  sed -i "s|<value>3</value>|<value>${bacnet_client_id}</value>|g" "$CFG" || true
fi

echo "[INFO] Starting ComfoBoxMqttConsole (attached to a PTY, no 'script' needed)"

# --- provide a real TTY for mono via socat ---
# This avoids "Not a tty" without requiring util-linux/script.
# socat creates a PTY and runs mono on the slave side.
cd "$APPDIR"

# Ensure we shutdown the TCP->PTY bridge when stopping
cleanup() {
  echo "[INFO] Shutting down..."
  if [ -n "${SOCAT_BRIDGE_PID:-}" ]; then
    kill "${SOCAT_BRIDGE_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

exec socat -d -d \
  "PTY,rawer,echo=0" \
  "EXEC:mono '${EXE_PATH}',pty,setsid,stderr"
