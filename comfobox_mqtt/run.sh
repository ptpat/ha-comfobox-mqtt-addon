#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] run.sh (Plan A stable unzip + socat + mono + targeted setting patch) starting"

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
mqtt_port="$(get_opt mqtt_port "1883")"          # RF77 config hat keinen Port-Setting, bleibt nur fürs Logging
mqtt_user="$(get_opt mqtt_user "")"              # RF77 config hat keinen User/Pass-Setting, bleibt nur fürs Logging
mqtt_pass="$(get_opt mqtt_pass "")"              # (und wird NICHT ins Log geschrieben)
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
find /app/rf77 -maxdepth 3 -type f -name "*.exe" -print

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

# --- socat (PTY -> TCP) ---
if [ "$use_socat" = "true" ]; then
  if [ -z "$waveshare_host" ] || [ "$waveshare_port" = "0" ]; then
    echo "[ERROR] socat enabled but waveshare_host/port not configured"
    exit 1
  fi

  echo "[INFO] Starting socat..."
  # robust PTY + link for the .NET app
  socat \
    "PTY,link=${serial_port},rawer,echo=0,waitslave" \
    "TCP:${waveshare_host}:${waveshare_port}" &

  sleep 1
  ls -la "$serial_port" || true
fi

# --- Targeted patch by setting-name (NO guessing by old values) ---
if [ -f "$CFG" ]; then
  echo "[INFO] Patching config (targeted setting-name patch)"

  tmp_cfg="$(mktemp)"

  awk -v baudrate="$baudrate" \
      -v port="$serial_port" \
      -v master="$bacnet_master_id" \
      -v client="$bacnet_client_id" \
      -v mqtthost="$mqtt_host" \
      -v basetopic="$mqtt_base_topic" '
    BEGIN {
      want="";
    }

    # Detect which setting we are inside (next <value> line will be replaced)
    /<setting[[:space:]]+name="Baudrate"[[:space:]]/            { want="Baudrate" }
    /<setting[[:space:]]+name="Port"[[:space:]]/                { want="Port" }
    /<setting[[:space:]]+name="BacnetMasterId"[[:space:]]/      { want="BacnetMasterId" }
    /<setting[[:space:]]+name="BacnetClientId"[[:space:]]/      { want="BacnetClientId" }
    /<setting[[:space:]]+name="MqttBrokerAddress"[[:space:]]/   { want="MqttBrokerAddress" }
    /<setting[[:space:]]+name="BaseTopic"[[:space:]]/           { want="BaseTopic" }

    # Replace only the immediate <value>...</value> line for the setting we want
    want != "" && /<value>.*<\/value>/ {
      if (want=="Baudrate")          { print "        <value>" baudrate "</value>"; want=""; next }
      if (want=="Port")              { print "        <value>" port "</value>"; want=""; next }
      if (want=="BacnetMasterId")    { print "        <value>" master "</value>"; want=""; next }
      if (want=="BacnetClientId")    { print "        <value>" client "</value>"; want=""; next }
      if (want=="MqttBrokerAddress") { print "        <value>" mqtthost "</value>"; want=""; next }
      if (want=="BaseTopic")         { print "        <value>" basetopic "</value>"; want=""; next }
    }

    { print }
  ' "$CFG" > "$tmp_cfg"

  mv "$tmp_cfg" "$CFG"

  echo "[INFO] Patched settings summary:"
  # show only the patched settings blocks quickly
  awk '
    /<setting name="Baudrate"/,/<\/setting>/ ||
    /<setting name="Port"/,/<\/setting>/ ||
    /<setting name="BacnetClientId"/,/<\/setting>/ ||
    /<setting name="BacnetMasterId"/,/<\/setting>/ ||
    /<setting name="MqttBrokerAddress"/,/<\/setting>/ ||
    /<setting name="BaseTopic"/,/<\/setting>/
  ' "$CFG" | sed -n '1,200p'
else
  echo "[WARN] Config file not found at $CFG (skipping patch)"
fi

echo "[INFO] Starting ComfoBoxMqttConsole"
cd "$APPDIR"
exec mono "$EXE_PATH"
