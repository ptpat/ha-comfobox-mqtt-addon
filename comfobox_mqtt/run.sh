#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] run.sh (Plan A: unzip + patch + socat(EXEC mono with PTY)) starting"

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
baudrate="$(get_opt baudrate "76800")"

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

patch_cfg_kv() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -q "key=\"$key\"" "$file" 2>/dev/null; then
    sed -i -E "s/(key=\"$key\"[[:space:]]+value=\")([^\"]*)(\")/\1${value}\3/g" "$file" || true
  fi
}

patch_setting_value() {
  # Patch <setting name="X"...><value>...</value>
  local name="$1"
  local value="$2"
  local file="$3"

  if grep -q "setting name=\"$name\"" "$file" 2>/dev/null; then
    # works across whitespace/newlines (simple, but reliable enough for this file)
    sed -i -E "s|(setting name=\"$name\"[^\n]*<value>)([^<]*)(</value>)|\1${value}\3|g" "$file" || true
  fi
}

if [ -f "$CFG" ]; then
  echo "[INFO] Patching config"

  patch_cfg_kv "MqttHost" "$mqtt_host" "$CFG"
  patch_cfg_kv "MqttPort" "$mqtt_port" "$CFG"
  patch_cfg_kv "MqttBaseTopic" "$mqtt_base_topic" "$CFG"
  patch_cfg_kv "SerialPort" "$serial_port" "$CFG"
  patch_cfg_kv "Baudrate" "$baudrate" "$CFG"
  patch_cfg_kv "BacnetMasterId" "$bacnet_master_id" "$CFG"
  patch_cfg_kv "BacnetClientId" "$bacnet_client_id" "$CFG"

  if [ -n "$mqtt_user" ]; then patch_cfg_kv "MqttUser" "$mqtt_user" "$CFG"; fi
  if [ -n "$mqtt_pass" ]; then patch_cfg_kv "MqttPassword" "$mqtt_pass" "$CFG"; fi

  # Fallbacks für RF77 Standardwerte
  sed -i "s|<value>localhost</value>|<value>${mqtt_host}</value>|g" "$CFG" || true
  sed -i "s|<value>COM8</value>|<value>${serial_port}</value>|g" "$CFG" || true
  sed -i "s|<value>76800</value>|<value>${baudrate}</value>|g" "$CFG" || true

  # *** EINZIGE neue Maßnahme gegen CPU-Loop: Schreiben von topics.md deaktivieren ***
  patch_setting_value "WriteTopicsToFile" "False" "$CFG"
fi

cd "$APPDIR"

if [ "$use_socat" = "true" ]; then
  if [ -z "$waveshare_host" ] || [ "$waveshare_port" = "0" ]; then
    echo "[ERROR] socat enabled but waveshare_host/port not configured"
    exit 1
  fi

  echo "[INFO] Starting ComfoBoxMqttConsole via socat (PTY + EXEC mono)"
  exec socat -d -d \
    "TCP:${waveshare_host}:${waveshare_port}" \
    "EXEC:mono '${EXE_PATH}',pty,setsid,stderr"
fi

echo "[INFO] Starting ComfoBoxMqttConsole (no socat)"
exec mono "$EXE_PATH"
