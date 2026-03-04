#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] run.sh (Plan A stable unzip + socat + mono + structured XML patch) starting"

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

# ---- options ----
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

bacnet_master_id="$(get_opt bacnet_master_id "11")"
bacnet_client_id="$(get_opt bacnet_client_id "3")"

echo "[INFO] waveshare=${waveshare_host}:${waveshare_port}"
echo "[INFO] serial=${serial_port} baud=${baudrate}"
echo "[INFO] mqtt=${mqtt_host}:${mqtt_port}"
echo "[INFO] mqtt_base_topic=${mqtt_base_topic}"
echo "[INFO] bacnet_master_id=${bacnet_master_id} bacnet_client_id=${bacnet_client_id}"

# ---- RF77 zip ----
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
find /app/rf77 -maxdepth 4 -type f -name "*.exe" -print || true

# Auto-detect console exe
EXE_PATH="$(find /app/rf77 -type f -name "ComfoBoxMqttConsole.exe" | head -n1 || true)"
if [ -z "$EXE_PATH" ]; then
  echo "[ERROR] ComfoBoxMqttConsole.exe not found after unzip"
  echo "[DEBUG] Full tree:"
  find /app/rf77 -maxdepth 6 -print
  exit 1
fi

APPDIR="$(dirname "$EXE_PATH")"
CFG="${EXE_PATH}.config"

echo "[INFO] RF77 detected at: $APPDIR"
echo "[INFO] Config file: $CFG"

# ---- socat PTY ----
if [ "$use_socat" = "true" ]; then
  if [ -z "$waveshare_host" ] || [ "$waveshare_port" = "0" ]; then
    echo "[ERROR] socat enabled but waveshare_host/port not configured"
    exit 1
  fi

  echo "[INFO] Starting socat..."
  # robust PTY + link
  socat \
    "PTY,link=${serial_port},rawer,echo=0,waitslave" \
    "TCP:${waveshare_host}:${waveshare_port}" &

  sleep 1
  ls -la "$serial_port" || true
fi

# ---- helpers for safe XML patching ----
patch_appsettings_key() {
  # patch <add key="X" value="Y" />
  local key="$1"
  local value="$2"
  local file="$3"
  # Only patch if the key exists; no structural rebuild here.
  sed -i -E "s|(<add[[:space:]]+key=\"${key}\"[[:space:]]+value=\")([^\"]*)(\"[[:space:]]*/?>)|\1${value}\3|g" "$file" || true
}

patch_setting_value() {
  # patch applicationSettings: <setting name="X"...><value>...</value></setting>
  local name="$1"
  local value="$2"
  local file="$3"
  # Works even if whitespace differs; uses a range between <setting name="X"...> and </setting>
  sed -i -E "/<setting[[:space:]]+name=\"${name}\"[[:space:]]+serializeAs=\"String\">/,/<\/setting>/ s|(<value>)([^<]*)(</value>)|\1${value}\3|g" "$file" || true
}

# ---- patch config ----
if [ -f "$CFG" ]; then
  echo "[INFO] Patching config (targeted keys/settings, no value-guessing)"

  # appSettings keys (if present)
  patch_appsettings_key "SerialPort"     "$serial_port" "$CFG"
  patch_appsettings_key "Baudrate"       "$baudrate"    "$CFG"
  patch_appsettings_key "MqttHost"       "$mqtt_host"   "$CFG"
  patch_appsettings_key "MqttPort"       "$mqtt_port"   "$CFG"
  if [ -n "$mqtt_user" ]; then patch_appsettings_key "MqttUser" "$mqtt_user" "$CFG"; fi
  if [ -n "$mqtt_pass" ]; then patch_appsettings_key "MqttPassword" "$mqtt_pass" "$CFG"; fi

  # applicationSettings (these are the RF77 ones you saw in logs)
  patch_setting_value "Port"              "$serial_port"      "$CFG"
  patch_setting_value "Baudrate"          "$baudrate"         "$CFG"
  patch_setting_value "MqttBrokerAddress" "$mqtt_host"        "$CFG"
  patch_setting_value "BaseTopic"         "$mqtt_base_topic"  "$CFG"
  patch_setting_value "BacnetMasterId"    "$bacnet_master_id" "$CFG"
  patch_setting_value "BacnetClientId"    "$bacnet_client_id" "$CFG"

else
  echo "[WARN] Config file not found ($CFG). Starting without patch."
fi

echo "[INFO] Starting ComfoBoxMqttConsole"
cd "$APPDIR"
exec mono "$EXE_PATH"
