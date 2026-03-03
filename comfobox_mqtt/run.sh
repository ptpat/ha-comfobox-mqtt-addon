#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] run.sh v5 (fix config order + appSettings rebuild) starting"

# ---- Read HA add-on options ----
WAVESHARE_HOST="$(jq -r '.waveshare_host' /data/options.json)"
WAVESHARE_PORT="$(jq -r '.waveshare_port' /data/options.json)"
SERIAL_PORT="$(jq -r '.serial_port' /data/options.json)"
BAUDRATE="$(jq -r '.baudrate' /data/options.json)"

MQTT_HOST="$(jq -r '.mqtt_host' /data/options.json)"
MQTT_PORT="$(jq -r '.mqtt_port' /data/options.json)"
MQTT_USER="$(jq -r '.mqtt_user' /data/options.json)"
MQTT_PASS="$(jq -r '.mqtt_pass' /data/options.json)"

USE_SOCAT="$(jq -r '.use_socat' /data/options.json)"

echo "[INFO] waveshare=${WAVESHARE_HOST}:${WAVESHARE_PORT}"
echo "[INFO] serial=${SERIAL_PORT} baud=${BAUDRATE}"
echo "[INFO] mqtt=${MQTT_HOST}:${MQTT_PORT} user_set=$([ -n "${MQTT_USER}" ] && [ "${MQTT_USER}" != "null" ] && echo yes || echo no)"

# ---- Start socat ----
if [ "${USE_SOCAT}" = "true" ]; then
  echo "[INFO] Starting socat..."
  socat -d -d "pty,raw,echo=0,link=${SERIAL_PORT}" "tcp:${WAVESHARE_HOST}:${WAVESHARE_PORT}" &
  sleep 2
fi

# ---- Locate RF77 console ----
BASE_DIR="/app/ComfoBox2Mqtt"
EXE="${BASE_DIR}/ComfoBoxMqttConsole.exe"
CFG="${BASE_DIR}/ComfoBoxMqttConsole.exe.config"

if [ ! -f "${EXE}" ] || [ ! -f "${CFG}" ]; then
  echo "[ERROR] Missing RF77 files in ${BASE_DIR}"
  ls -la "${BASE_DIR}" || true
  exit 1
fi

echo "[INFO] Rebuilding <appSettings> safely (configSections must stay first)..."

# 1) Remove ANY existing appSettings blocks (they might be in the wrong place)
#    This fixes the "configSections must be first" issue.
sed -i '/<appSettings>/,/<\/appSettings>/d' "${CFG}"

# 2) Build a fresh appSettings block in a temp file
TMP_APP="/tmp/appsettings.xml"
{
  echo "  <appSettings>"
  echo "    <add key=\"SerialPort\" value=\"${SERIAL_PORT}\" />"
  echo "    <add key=\"Baudrate\" value=\"${BAUDRATE}\" />"
  echo "    <add key=\"MqttHost\" value=\"${MQTT_HOST}\" />"
  echo "    <add key=\"MqttPort\" value=\"${MQTT_PORT}\" />"
  if [ -n "${MQTT_USER}" ] && [ "${MQTT_USER}" != "null" ]; then
    echo "    <add key=\"MqttUser\" value=\"${MQTT_USER}\" />"
  fi
  if [ -n "${MQTT_PASS}" ] && [ "${MQTT_PASS}" != "null" ]; then
    echo "    <add key=\"MqttPassword\" value=\"${MQTT_PASS}\" />"
  fi
  echo "  </appSettings>"
} > "${TMP_APP}"

# 3) Insert the appSettings in the correct place:
#    after </configSections> if it exists; otherwise right after <configuration>
if grep -q "</configSections>" "${CFG}"; then
  # Insert after closing configSections
  sed -i "/<\/configSections>/r ${TMP_APP}" "${CFG}"
else
  # Insert after <configuration> opening tag
  sed -i "/<configuration>/r ${TMP_APP}" "${CFG}"
fi

# 4) Debug: show structure markers + redact password
echo "-----------------------------------------"
echo "[DEBUG] CFG markers:"
grep -n -E "<configuration>|</configuration>|<configSections>|</configSections>|<appSettings>|</appSettings>" "${CFG}" || true
echo "-----------------------------------------"
echo "[DEBUG] appSettings (password redacted):"
sed -E 's/(key="MqttPassword" value=")[^"]*"/\1***"/g' "${CFG}" | grep -n -E "<appSettings>|</appSettings>|<add key=" || true
echo "-----------------------------------------"

echo "[INFO] Starting ComfoBoxMqttConsole..."
cd "${BASE_DIR}"
exec mono ./ComfoBoxMqttConsole.exe
