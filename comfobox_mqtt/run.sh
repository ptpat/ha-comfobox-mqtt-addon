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

# --- options ---
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

# --- RF77 package (bundled in /app) ---
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

# --- auto-detect exe ---
EXE_PATH="$(find /app/rf77 -type f -name "ComfoBoxMqttConsole.exe" | head -n1 || true)"
if [ -z "$EXE_PATH" ]; then
  echo "[ERROR] ComfoBoxMqttConsole.exe not found after unzip"
  echo "[DEBUG] Full tree:"
  find /app/rf77 -maxdepth 6 -print || true
  exit 1
fi

APPDIR="$(dirname "$EXE_PATH")"
CFG="${EXE_PATH}.config"

echo "[INFO] RF77 detected at: $APPDIR"
echo "[INFO] Config file: $CFG"

# --- socat TCP->PTY bridge for Waveshare ---
if [ "$use_socat" = "true" ]; then
  if [ -z "$waveshare_host" ] || [ "$waveshare_port" = "0" ]; then
    echo "[ERROR] use_socat=true but waveshare_host/port not set"
    exit 1
  fi

  echo "[INFO] Starting socat (TCP->PTY)..."
  socat \
    "PTY,link=${serial_port},rawer,echo=0,waitslave" \
    "TCP:${waveshare_host}:${waveshare_port}" &
  sleep 1
  ls -la "$serial_port" || true
fi

# --- patch config (targeted by setting-name / known keys, no guessing) ---
if [ -f "$CFG" ]; then
  echo "[INFO] Patching config"

  # Helper: replace <setting name="X"> ... <value>OLD</value> with NEW (within that setting block)
  replace_setting_value() {
    local setting="$1"
    local newval="$2"
    # Replace only the first <value>...</value> within the matching <setting name="..."> block
    awk -v setting="$setting" -v newval="$newval" '
      BEGIN{inset=0; done=0}
      {
        line=$0
        if (line ~ "<setting name=\""setting"\"") { inset=1 }
        if (inset==1 && done==0 && line ~ "<value>") {
          sub(/<value>[^<]*<\/value>/, "<value>" newval "</value>", line)
          done=1
        }
        print line
        if (inset==1 && line ~ "</setting>") { inset=0; done=0 }
      }
    ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  }

  # ComfoBoxLib.Properties.Settings
  replace_setting_value "Baudrate"            "${baudrate}"
  replace_setting_value "Port"                "${serial_port}"
  replace_setting_value "BacnetClientId"      "${bacnet_client_id}"
  replace_setting_value "BacnetMasterId"      "${bacnet_master_id}"
  replace_setting_value "MqttBrokerAddress"   "${mqtt_host}"

  # ComfoBoxMqtt.Properties.Settings
  replace_setting_value "BaseTopic"           "${mqtt_base_topic}"

  # Optional: if the app also reads appSettings keys, ensure they exist/updated (best-effort)
  # Keep it simple: only substitute if keys already exist.
  sed -i "s|<add key=\"MqttHost\" value=\"[^\"]*\" />|<add key=\"MqttHost\" value=\"${mqtt_host}\" />|g" "$CFG" || true
  sed -i "s|<add key=\"MqttPort\" value=\"[^\"]*\" />|<add key=\"MqttPort\" value=\"${mqtt_port}\" />|g" "$CFG" || true
  sed -i "s|<add key=\"SerialPort\" value=\"[^\"]*\" />|<add key=\"SerialPort\" value=\"${serial_port}\" />|g" "$CFG" || true
  sed -i "s|<add key=\"Baudrate\" value=\"[^\"]*\" />|<add key=\"Baudrate\" value=\"${baudrate}\" />|g" "$CFG" || true

  if [ -n "$mqtt_user" ]; then
    sed -i "s|<add key=\"MqttUser\" value=\"[^\"]*\" />|<add key=\"MqttUser\" value=\"${mqtt_user}\" />|g" "$CFG" || true
  fi
  if [ -n "$mqtt_pass" ]; then
    # Avoid printing password; just set if key exists
    sed -i "s|<add key=\"MqttPassword\" value=\"[^\"]*\" />|<add key=\"MqttPassword\" value=\"${mqtt_pass}\" />|g" "$CFG" || true
  fi
fi

# --- start mono in a way that won't cause CPU/log storms on crash ---
echo "[INFO] Starting ComfoBoxMqttConsole (attached to a PTY; low-noise)"
cd "$APPDIR"

# If mono exits immediately, pause a bit to avoid restart/CPU storm
set +e
socat \
  "PTY,rawer,echo=0" \
  "EXEC:/bin/sh -lc \"exec mono \\\"$EXE_PATH\\\"\",pty,setsid,stderr"
rc=$?
echo "[ERROR] ComfoBoxMqttConsole exited with rc=$rc"
sleep 10
exit $rc
