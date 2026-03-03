#!/usr/bin/with-contenv bashio
set -euo pipefail

echo "[INFO] run.sh v7 (patch applicationSettings + socat + start mono) starting"

# --- Read add-on options ---
USE_SOCAT="$(bashio::config 'use_socat')"
WAVESHARE_HOST="$(bashio::config 'waveshare_host')"
WAVESHARE_PORT="$(bashio::config 'waveshare_port')"
SERIAL_PORT="$(bashio::config 'serial_port')"
BAUDRATE="$(bashio::config 'baudrate')"

MQTT_HOST="$(bashio::config 'mqtt_host')"
MQTT_PORT="$(bashio::config 'mqtt_port')"
MQTT_USER="$(bashio::config 'mqtt_user')"
MQTT_PASS="$(bashio::config 'mqtt_pass')"

USER_SET="no"
if [[ -n "${MQTT_USER}" ]]; then USER_SET="yes"; fi

echo "[INFO] waveshare=${WAVESHARE_HOST}:${WAVESHARE_PORT}"
echo "[INFO] serial=${SERIAL_PORT} baud=${BAUDRATE}"
echo "[INFO] mqtt=${MQTT_HOST}:${MQTT_PORT} user_set=${USER_SET}"

# --- Locate RF77 console folder ---
APP_DIR="/app"
CONSOLE_DIR=""

if [[ -d "${APP_DIR}/ComfoBox2Mqtt" ]]; then
  CONSOLE_DIR="${APP_DIR}/ComfoBox2Mqtt"
else
  # try to find it
  CANDIDATE="$(find "${APP_DIR}" -maxdepth 3 -type f -name "ComfoBoxMqttConsole.exe" -print -quit 2>/dev/null || true)"
  if [[ -n "${CANDIDATE}" ]]; then
    CONSOLE_DIR="$(dirname "${CANDIDATE}")"
  fi
fi

if [[ -z "${CONSOLE_DIR}" ]]; then
  echo "[ERROR] ComfoBoxMqttConsole.exe not found. Listing /app:"
  ls -la "${APP_DIR}" || true
  exit 1
fi

echo "[INFO] Found console in: ${CONSOLE_DIR}"

CFG="${CONSOLE_DIR}/ComfoBoxMqttConsole.exe.config"
if [[ ! -f "${CFG}" ]]; then
  echo "[ERROR] Config not found: ${CFG}"
  ls -la "${CONSOLE_DIR}" || true
  exit 1
fi

# --- Helper: patch <setting name="X"><value>Y</value> in applicationSettings (line-based) ---
patch_app_setting() {
  local file="$1"
  local setting="$2"
  local new_value="$3"

  # escape & for awk replacement
  local safe_value="${new_value//&/\\&}"

  awk -v setting="$setting" -v value="$safe_value" '
    BEGIN { in_setting=0; patched=0 }
    $0 ~ "<setting name=\"" setting "\"" { in_setting=1 }
    in_setting==1 && $0 ~ /<value>.*<\/value>/ {
      sub(/<value>[^<]*<\/value>/, "<value>" value "</value>")
      in_setting=0
      patched=1
    }
    { print }
    END {
      if (patched==0) {
        # Not fatal — some settings may not exist in some RF77 versions
      }
    }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# --- Helper: patch/create appSettings block (legacy) ---
patch_appsettings_block() {
  local file="$1"

  # If no <appSettings>, add a minimal block right after </configSections>
  if ! grep -q "<appSettings>" "$file"; then
    awk '
      { print }
      /<\/configSections>/ && inserted==0 {
        print "  <appSettings>"
        print "  </appSettings>"
        inserted=1
      }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi

  # Now rebuild <appSettings> content safely
  awk -v serial="${SERIAL_PORT}" \
      -v baud="${BAUDRATE}" \
      -v mh="${MQTT_HOST}" \
      -v mp="${MQTT_PORT}" \
      -v mu="${MQTT_USER}" \
      -v mpass="${MQTT_PASS}" '
    BEGIN { in_as=0 }
    /<appSettings>/ {
      print "  <appSettings>"
      print "    <add key=\"SerialPort\" value=\"" serial "\" />"
      print "    <add key=\"Baudrate\" value=\"" baud "\" />"
      print "    <add key=\"MqttHost\" value=\"" mh "\" />"
      print "    <add key=\"MqttPort\" value=\"" mp "\" />"
      if (length(mu) > 0) {
        print "    <add key=\"MqttUser\" value=\"" mu "\" />"
        print "    <add key=\"MqttPassword\" value=\"" mpass "\" />"
      }
      print "  </appSettings>"
      in_as=1
      next
    }
    in_as==1 && /<\/appSettings>/ { in_as=0; next }
    in_as==1 { next }
    { print }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

echo "[INFO] Patching RF77 config: ${CFG}"

# 1) Patch the real RF77 settings (applicationSettings) — THIS is the key fix
patch_app_setting "${CFG}" "MqttBrokerAddress" "${MQTT_HOST}"
patch_app_setting "${CFG}" "MqttPort" "${MQTT_PORT}"
patch_app_setting "${CFG}" "Port" "${SERIAL_PORT}"
patch_app_setting "${CFG}" "Baudrate" "${BAUDRATE}"

# 2) Also patch legacy appSettings (harmless, but keeps things consistent)
patch_appsettings_block "${CFG}"

# --- Start socat (if enabled) ---
if [[ "${USE_SOCAT}" == "true" ]]; then
  echo "[INFO] Starting socat..."
  # Create PTY and link it to SERIAL_PORT
  socat -d -d \
    pty,raw,echo=0,link="${SERIAL_PORT}",mode=666 \
    "tcp:${WAVESHARE_HOST}:${WAVESHARE_PORT}" &
  SOCAT_PID=$!

  # give socat a moment
  sleep 2

  if ! kill -0 "${SOCAT_PID}" 2>/dev/null; then
    echo "[ERROR] socat failed to start"
    exit 1
  fi
else
  echo "[WARN] use_socat=false, not starting socat"
fi

# --- Quick debug dump (redact password) ---
echo "-----------------------------------------"
echo "[DEBUG] applicationSettings (relevant lines, password redacted):"
grep -nE 'setting name="(MqttBrokerAddress|MqttPort|Port|Baudrate)"|<value>' "${CFG}" \
  | sed -E 's/(MqttPassword".*<value>)[^<]*/\1*** /' || true
echo "-----------------------------------------"
echo "[DEBUG] appSettings (password redacted):"
grep -nE '<appSettings>|</appSettings>|<add key="(SerialPort|Baudrate|MqttHost|MqttPort|MqttUser|MqttPassword)"' "${CFG}" \
  | sed -E 's/(MqttPassword" value=")[^"]*/\1*** /' || true
echo "-----------------------------------------"

# --- Start RF77 console ---
echo "[INFO] Starting ComfoBoxMqttConsole..."
cd "${CONSOLE_DIR}"
exec mono "ComfoBoxMqttConsole.exe"
