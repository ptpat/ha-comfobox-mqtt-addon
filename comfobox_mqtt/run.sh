#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] run.sh (jq + unzip + socat TCP->PTY + ln -sf + patch + mono) starting"

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
  local name="$1"
  local newval="$2"
  local file="$3"

  if ! grep -q "setting name=\"$name\"" "$file" 2>/dev/null; then
    return 0
  fi

  sed -i -E "/setting name=\"$name\"/,/<\/setting>/ s|<value>[^<]*</value>|<value>${newval}</value>|" "$file" || true
}

SOCAT_PID=""
cleanup() {
  if [ -n "${SOCAT_PID}" ]; then
    kill "${SOCAT_PID}" >/dev/null 2>&1 || true
    wait "${SOCAT_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- Start socat and create /tmp/comfobox (without socat link=) ---
if [ "$use_socat" = "true" ]; then
  if [ -z "$waveshare_host" ] || [ "$waveshare_port" = "0" ]; then
    echo "[ERROR] use_socat=true but waveshare_host/port not configured"
    exit 1
  fi

  echo "[INFO] Starting socat (TCP->PTY) in background..."
  SOCAT_LOG="/tmp/socat.log"
  rm -f "$SOCAT_LOG" >/dev/null 2>&1 || true

  (socat -d -d "TCP:${waveshare_host}:${waveshare_port},keepalive,nodelay" "PTY,raw,echo=0,waitslave" 2>"$SOCAT_LOG") &
  SOCAT_PID="$!"

  PTY=""
  for _ in $(seq 1 50); do
    PTY="$(grep -oE '/dev/pts/[0-9]+' "$SOCAT_LOG" | head -n1 || true)"
    if [ -n "$PTY" ] && [ -c "$PTY" ]; then
      break
    fi
    sleep 0.1
  done

  if [ -z "$PTY" ]; then
    echo "[ERROR] Could not detect PTY from socat log"
    tail -n 80 "$SOCAT_LOG" || true
    exit 1
  fi

  echo "[INFO] Detected PTY: $PTY"
  echo "[INFO] Creating symlink: ${serial_port} -> ${PTY}"
  rm -f "${serial_port}" >/dev/null 2>&1 || true
  ln -sf "${PTY}" "${serial_port}" || true
  ls -la "${serial_port}" || true
fi

# --- Patch RF77 config ---
if [ -f "$CFG" ]; then
  echo "[INFO] Patching RF77 config"

  patch_setting_value_multiline "Port" "${serial_port}" "$CFG"
  patch_setting_value_multiline "Baudrate" "${baudrate}" "$CFG"
  patch_setting_value_multiline "BacnetMasterId" "${bacnet_master_id}" "$CFG"
  patch_setting_value_multiline "BacnetClientId" "${bacnet_client_id}" "$CFG"

  patch_setting_value_multiline "MqttBrokerAddress" "${mqtt_host}" "$CFG"
  patch_setting_value_multiline "BaseTopic" "${mqtt_base_topic}" "$CFG"
  patch_setting_value_multiline "WriteTopicsToFile" "False" "$CFG"
fi

cd "$APPDIR"

echo "[INFO] Starting ComfoBoxMqttConsole"
exec mono "$EXE_PATH"
