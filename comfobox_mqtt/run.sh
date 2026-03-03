#!/usr/bin/with-contenv bashio
set -euo pipefail

echo "[INFO] run.sh v8 (robust socat PTY + patch applicationSettings + start mono) starting"

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
  CANDIDATE="$(find "${APP_DIR}" -maxdepth 4 -type f -name "ComfoBoxMqttConsole.exe" -print -quit 2>/dev/null || true)"
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
EXE="${CONSOLE_DIR}/ComfoBoxMqttConsole.exe"

if [[ ! -f "${CFG}" ]]; then
  echo "[ERROR] Config not found: ${CFG}"
  ls -la "${CONSOLE_DIR}" || true
  exit 1
fi

if [[ ! -f "${EXE}" ]]; then
  echo "[ERROR] EXE not found: ${EXE}"
  ls -la "${CONSOLE_DIR}" || true
  exit 1
fi

# --- Helper: patch <setting name="X"><value>Y</value> in applicationSettings (line-based) ---
patch_app_setting() {
  local file="$1"
  local setting="$2"
  local new_value="$3"
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
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# --- Helper: ensure appSettings exists and rebuild it (legacy; harmless but keeps consistency) ---
rebuild_appsettings_block() {
  local file="$1"

  # If no <appSettings>, add minimal block right after </configSections> if present, else after <configuration>
  if ! grep -q "<appSettings>" "$file"; then
    if grep -q "</configSections>" "$file"; then
      awk '
        { print }
        /<\/configSections>/ && inserted==0 {
          print "  <appSettings>"
          print "  </appSettings>"
          inserted=1
        }
      ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
      awk '
        { print }
        /<configuration>/ && inserted==0 {
          print "  <appSettings>"
          print "  </appSettings>"
          inserted=1
        }
      ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
  fi

  # Rebuild the entire <appSettings> content
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

# --- Patch the REAL RF77 settings (applicationSettings) ---
# Serial
patch_app_setting "${CFG}" "Port" "${SERIAL_PORT}"
patch_app_setting "${CFG}" "Baudrate" "${BAUDRATE}"

# MQTT (RF77 uses MqttBrokerAddress; some builds also have MqttPort but yours currently not shown)
patch_app_setting "${CFG}" "MqttBrokerAddress" "${MQTT_HOST}"
patch_app_setting "${CFG}" "MqttPort" "${MQTT_PORT}"

# --- Also keep legacy appSettings consistent ---
rebuild_appsettings_block "${CFG}"

# --- Start socat (robust PTY) ---
SOCAT_PID=""
if [[ "${USE_SOCAT}" == "true" ]]; then
  if [[ -z "${WAVESHARE_HOST}" || -z "${WAVESHARE_PORT}" ]]; then
    echo "[ERROR] use_socat=true but waveshare_host/port missing"
    exit 1
  fi

  echo "[INFO] Starting socat (robust PTY)..."
  # rawer + waitslave makes PTY behave more like a real serial port for Mono SerialPort
  socat -d -d \
    "PTY,link=${SERIAL_PORT},rawer,echo=0,waitslave,mode=666" \
    "TCP:${WAVESHARE_HOST}:${WAVESHARE_PORT},nodelay" &
  SOCAT_PID="$!"

  sleep 2

  echo "[DEBUG] serial link:"
  ls -l "${SERIAL_PORT}" || true
  echo "[DEBUG] /dev/pts:"
  ls -l /dev/pts || true

  if ! kill -0 "${SOCAT_PID}" 2>/dev/null; then
    echo "[ERROR] socat failed to start"
    exit 1
  fi
else
  echo "[WARN] use_socat=false, not starting socat"
fi

# --- Debug dump (redact password) ---
echo "-----------------------------------------"
echo "[DEBUG] applicationSettings (relevant lines):"
grep -nE 'setting name="(MqttBrokerAddress|MqttPort|Port|Baudrate)"|<value>' "${CFG}" || true
echo "-----------------------------------------"
echo "[DEBUG] appSettings (password redacted):"
grep -nE '<appSettings>|</appSettings>|<add key="(SerialPort|Baudrate|MqttHost|MqttPort|MqttUser|MqttPassword)"' "${CFG}" \
  | sed -E 's/(MqttPassword" value=")[^"]*/\1*** /' || true
echo "-----------------------------------------"

# --- Start RF77 console ---
echo "[INFO] Starting ComfoBoxMqttConsole..."
cd "${CONSOLE_DIR}"
exec mono "ComfoBoxMqttConsole.exe"
