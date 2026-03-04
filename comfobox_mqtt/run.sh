#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] run.sh (Plan A stable unzip + socat + mono) starting"

OPTIONS_JSON="/data/options.json"

get_opt() {
  local key="$1"
  local def="${2:-}"
  if command -v jq >/dev/null 2>&1; then
    local val
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

echo "[INFO] waveshare=${waveshare_host}:${waveshare_port}"
echo "[INFO] serial=${serial_port} baud=${baudrate}"
echo "[INFO] mqtt=${mqtt_host}:${mqtt_port}"

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
find /app/rf77 -maxdepth 3 -type f -name "*.exe" -print

# --- auto-detect exe ---
EXE_PATH="$(find /app/rf77 -type f -name "ComfoBoxMqttConsole.exe" | head -n1 || true)"

if [ -z "$EXE_PATH" ]; then
  echo "[ERROR] ComfoBoxMqttConsole.exe not found after unzip"
  echo "[DEBUG] Full tree:"
  find /app/rf77 -maxdepth 5 -print
  exit 1
fi

APPDIR="$(dirname "$EXE_PATH")"
CFG="${EXE_PATH}.config"

echo "[INFO] RF77 detected at: $APPDIR"

# --- socat ---
if [ "$use_socat" = "true" ]; then
  if [ -z "$waveshare_host" ] || [ "$waveshare_port" = "0" ]; then
    echo "[ERROR] socat enabled but waveshare not configured"
    exit 1
  fi

  echo "[INFO] Starting socat..."
  # robust PTY bridge
  socat \
    "PTY,link=${serial_port},rawer,echo=0,waitslave" \
    "TCP:${waveshare_host}:${waveshare_port}" &
  sleep 1
  ls -la "$serial_port" || true
fi

# --- minimal config patch (only safe replacements) ---
if [ -f "$CFG" ]; then
  echo "[INFO] Patching config"
  # MQTT broker address (RF77 uses applicationSettings->MqttBrokerAddress default localhost)
  sed -i "s|<value>localhost</value>|<value>${mqtt_host}</value>|g" "$CFG" || true
  # serial port
  sed -i "s|<value>COM8</value>|<value>${serial_port}</value>|g" "$CFG" || true
  # baudrate default in RF77 config is 76800, replace that (not 38400!)
  sed -i "s|<value>76800</value>|<value>${baudrate}</value>|g" "$CFG" || true
fi

echo "[INFO] Starting ComfoBoxMqttConsole"
cd "$APPDIR"

# ---- IMPORTANT CHANGE: run inside a PTY to avoid 'Not a tty' loops ----
# 'script' is provided by util-linux; ensure it's installed in the image.
exec script -q -c "mono \"$EXE_PATH\"" /dev/null
