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

echo "[INFO] waveshare=${waveshare_host}:${waveshare_port}"
echo "[INFO] serial=${serial_port} baud=${baudrate}"
echo "[INFO] mqtt=${mqtt_host}:${mqtt_port}"

ZIP="/app/ComfoBox2Mqtt_0.4.0.zip"

if [ ! -f "$ZIP" ]; then
  echo "[ERROR] ZIP not found at $ZIP"
  exit 1
fi

rm -rf /app/rf77
mkdir -p /app/rf77
unzip -o "$ZIP" -d /app/rf77 >/dev/null

EXE_PATH="$(find /app/rf77 -type f -name "ComfoBoxMqttConsole.exe" | head -n1 || true)"
if [ -z "$EXE_PATH" ]; then
  echo "[ERROR] EXE not found"
  exit 1
fi

APPDIR="$(dirname "$EXE_PATH")"
CFG="${EXE_PATH}.config"

if [ "$use_socat" = "true" ]; then
  socat \
    "PTY,link=${serial_port},rawer,echo=0,waitslave" \
    "TCP:${waveshare_host}:${waveshare_port}" &
  sleep 1
fi

if [ -f "$CFG" ]; then
  sed -i "s|<value>localhost</value>|<value>${mqtt_host}</value>|g" "$CFG"
  sed -i "s|<value>COM8</value>|<value>${serial_port}</value>|g" "$CFG"
  sed -i "s|<value>76800</value>|<value>${baudrate}</value>|g" "$CFG"

  # BACnet zurück auf funktionierenden Stand
  sed -i '/BacnetMasterId/{n;s|<value>.*</value>|<value>1</value>|}' "$CFG"
  sed -i '/BacnetClientId/{n;s|<value>.*</value>|<value>3</value>|}' "$CFG"
fi

cd "$APPDIR"
exec mono "$EXE_PATH"
