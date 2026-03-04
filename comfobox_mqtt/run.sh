#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] run.sh (jq + unzip + patch + socat TCP<->EXEC(mono) with PTY) starting"

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

waveshare_host="$(get_opt waveshare_host "")"
waveshare_port="$(get_opt waveshare_port "0")"

baudrate="$(get_opt baudrate "76800")"

mqtt_host="$(get_opt mqtt_host "core-mosquitto")"
mqtt_base_topic="$(get_opt mqtt_base_topic "ComfoBox")"

bacnet_master_id="$(get_opt bacnet_master_id "1")"
bacnet_client_id="$(get_opt bacnet_client_id "3")"

echo "[INFO] waveshare=${waveshare_host}:${waveshare_port}"
echo "[INFO] baud=${baudrate}"
echo "[INFO] mqtt=${mqtt_host}"
echo "[INFO] mqtt_base_topic=${mqtt_base_topic}"
echo "[INFO] bacnet_master_id=${bacnet_master_id} bacnet_client_id=${bacnet_client_id}"

if [ -z "$waveshare_host" ] || [ "$waveshare_port" = "0" ]; then
  echo "[ERROR] waveshare_host/port not configured"
  exit 1
fi

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
  echo "[ERROR] ComfoBoxMqttConsole.exe not found after unzip"
  find /app/rf77 -maxdepth 6 -print || true
  exit 1
fi

APPDIR="$(dirname "$EXE_PATH")"
CFG="${EXE_PATH}.config"
cd "$APPDIR"

patch_setting_value_multiline() {
  local name="$1"
  local newval="$2"
  local file="$3"
  if ! grep -q "setting name=\"$name\"" "$file" 2>/dev/null; then
    return 0
  fi
  sed -i -E "/setting name=\"$name\"/,/<\/setting>/ s|<value>[^<]*</value>|<value>${newval}</value>|" "$file" || true
}

if [ -f "$CFG" ]; then
  echo "[INFO] Patching RF77 config"

  patch_setting_value_multiline "Baudrate" "${baudrate}" "$CFG"
  patch_setting_value_multiline "BacnetMasterId" "${bacnet_master_id}" "$CFG"
  patch_setting_value_multiline "BacnetClientId" "${bacnet_client_id}" "$CFG"

  patch_setting_value_multiline "MqttBrokerAddress" "${mqtt_host}" "$CFG"
  patch_setting_value_multiline "BaseTopic" "${mqtt_base_topic}" "$CFG"
  patch_setting_value_multiline "WriteTopicsToFile" "False" "$CFG"

  # IMPORTANT: do NOT force Port to /tmp/comfobox here; let RF77 use its internal stream
  # If RF77 requires Port, set it to "COM8" equivalent or leave as-is.
fi

echo "[INFO] Starting socat TCP<->EXEC(mono) with PTY"
exec socat -d -d \
  "TCP:${waveshare_host}:${waveshare_port},keepalive,nodelay" \
  "EXEC:mono '${EXE_PATH}',pty,raw,echo=0,setsid,stderr"
