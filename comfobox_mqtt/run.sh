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

# ---- Options (Home Assistant add-on config.yaml -> options.json) ----
use_socat="$(get_opt use_socat "true")"
waveshare_host="$(get_opt waveshare_host "")"
waveshare_port="$(get_opt waveshare_port "0")"

serial_port="$(get_opt serial_port "/tmp/comfobox")"
baudrate="$(get_opt baudrate "76800")"

mqtt_host="$(get_opt mqtt_host "core-mosquitto")"
mqtt_port="$(get_opt mqtt_port "1883")"
mqtt_base_topic="$(get_opt mqtt_base_topic "ComfoBox")"

# NEW: BACnet IDs configurable (yesterday goal)
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
  echo "[ERROR] EXE not found"
  exit 1
fi

APPDIR="$(dirname "$EXE_PATH")"
CFG="${EXE_PATH}.config"

echo "[INFO] RF77 detected at: $APPDIR"
echo "[INFO] Config file: $CFG"

# ---- socat TCP -> PTY (Waveshare TCP serial server) ----
if [ "$use_socat" = "true" ]; then
  if [ -z "$waveshare_host" ] || [ "$waveshare_port" = "0" ]; then
    echo "[ERROR] socat enabled but waveshare_host/port not configured"
    exit 1
  fi

  echo "[INFO] Starting socat (TCP->PTY)..."
  # Kill possible old socat instances using the same link
  pkill -f "socat.*${serial_port}" >/dev/null 2>&1 || true
  rm -f "${serial_port}" >/dev/null 2>&1 || true

  socat \
    "TCP:${waveshare_host}:${waveshare_port}" \
    "PTY,link=${serial_port},rawer,echo=0,waitslave" &

  sleep 1
  ls -la "$serial_port" || true
fi

# ---- minimal config patch (only what we need) ----
if [ -f "$CFG" ]; then
  echo "[INFO] Patching config"

  # Try robust, setting-based replacements first (preferred)
  # These work if the config contains <setting name="X"><value>...</value>
  sed -i '/<setting name="MqttHost"/{n;s|<value>.*</value>|<value>'"${mqtt_host}"'</value>|;}' "$CFG" || true
  sed -i '/<setting name="MqttPort"/{n;s|<value>.*</value>|<value>'"${mqtt_port}"'</value>|;}' "$CFG" || true
  sed -i '/<setting name="MqttBaseTopic"/{n;s|<value>.*</value>|<value>'"${mqtt_base_topic}"'</value>|;}' "$CFG" || true

  sed -i '/<setting name="SerialPort"/{n;s|<value>.*</value>|<value>'"${serial_port}"'</value>|;}' "$CFG" || true
  sed -i '/<setting name="Baudrate"/{n;s|<value>.*</value>|<value>'"${baudrate}"'</value>|;}' "$CFG" || true

  sed -i '/<setting name="BacnetMasterId"/{n;s|<value>.*</value>|<value>'"${bacnet_master_id}"'</value>|;}' "$CFG" || true
  sed -i '/<setting name="BacnetClientId"/{n;s|<value>.*</value>|<value>'"${bacnet_client_id}"'</value>|;}' "$CFG" || true

  # Fallbacks (for older configs that may have literal defaults)
  sed -i "s|<value>localhost</value>|<value>${mqtt_host}</value>|g" "$CFG" || true
  sed -i "s|<value>COM8</value>|<value>${serial_port}</value>|g" "$CFG" || true

  # Keep your old behavior: if the upstream config hardcodes 76800 somewhere, allow overriding it.
  sed -i "s|<value>76800</value>|<value>${baudrate}</value>|g" "$CFG" || true
fi

cd "$APPDIR"
echo "[INFO] Starting ComfoBoxMqttConsole"
exec mono "$EXE_PATH"
