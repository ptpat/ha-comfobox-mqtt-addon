#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] run.sh (Plan A: unzip + patch + dump-config + socat(EXEC mono with PTY)) starting"

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

patch_setting_value_multiline() {
  # Replace the <value>...</value> inside a <setting name="X"> ... </setting> block
  local name="$1"
  local newval="$2"
  local file="$3"

  if ! grep -q "setting name=\"$name\"" "$file" 2>/dev/null; then
    return 0
  fi

  # sed range from the line containing the setting name until </setting>, then replace the first <value>...</value>
  sed -i -E "/setting name=\"$name\"/,/<\/setting>/ s|<value>[^<]*</value>|<value>${newval}</value>|" "$file" || true
}

if [ -f "$CFG" ]; then
  echo "[INFO] Patching config"

  # Patch known defaults (safe)
  sed -i "s|<value>localhost</value>|<value>${mqtt_host}</value>|g" "$CFG" || true
  sed -i "s|<value>COM8</value>|<value>${serial_port}</value>|g" "$CFG" || true
  sed -i "s|<value>76800</value>|<value>${baudrate}</value>|g" "$CFG" || true

  # Multiline-safe setting patches
  patch_setting_value_multiline "BacnetMasterId" "${bacnet_master_id}" "$CFG"
  patch_setting_value_multiline "BacnetClientId" "${bacnet_client_id}" "$CFG"
  patch_setting_value_multiline "WriteTopicsToFile" "False" "$CFG"
  patch_setting_value_multiline "BaseTopic" "${mqtt_base_topic}" "$CFG"
  patch_setting_value_multiline "MqttBrokerAddress" "${mqtt_host}" "$CFG"

  echo "[INFO] Dumping effective settings (post-patch):"
  grep -n -E 'setting name="(Baudrate|Port|BacnetClientId|BacnetMasterId|MqttBrokerAddress|BaseTopic|WriteTopicsToFile)"' "$CFG" || true
  grep -n -E '<value>(/tmp/comfobox|core-mosquitto|False|True|[0-9]{1,6})</value>' "$CFG" | head -n 120 || true
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
