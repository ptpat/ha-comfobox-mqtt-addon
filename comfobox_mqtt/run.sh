#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] run.sh v4 (inspect config structure) starting"

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

if [ "${USE_SOCAT}" = "true" ]; then
  echo "[INFO] Starting socat..."
  socat -d -d "pty,raw,echo=0,link=${SERIAL_PORT}" "tcp:${WAVESHARE_HOST}:${WAVESHARE_PORT}" &
  sleep 2
fi

BASE_DIR="/app/ComfoBox2Mqtt"
EXE="${BASE_DIR}/ComfoBoxMqttConsole.exe"
CFG="${BASE_DIR}/ComfoBoxMqttConsole.exe.config"

if [ ! -f "${EXE}" ] || [ ! -f "${CFG}" ]; then
  echo "[ERROR] Missing RF77 files in ${BASE_DIR}"
  ls -la "${BASE_DIR}" || true
  exit 1
fi

echo "[INFO] Patching RF77 config (best effort)..."

# --- ensure appSettings exists; if not, create it right after <configuration> ---
if ! grep -q "<appSettings>" "${CFG}"; then
  echo "[WARN] No <appSettings> found; creating <appSettings> block."
  # Insert right after first <configuration> tag
  sed -i '0,/<configuration>/s//<configuration>\n  <appSettings>\n  <\/appSettings>/' "${CFG}"
fi

set_xml_kv() {
  local key="$1"
  local val="$2"

  if grep -q "key=\"${key}\"" "${CFG}"; then
    sed -i "s|<add key=\"${key}\" value=\"[^\"]*\" */>|<add key=\"${key}\" value=\"${val}\" />|g" "${CFG}"
  else
    sed -i "s|</appSettings>|  <add key=\"${key}\" value=\"${val}\" />\n</appSettings>|" "${CFG}"
  fi
}

set_xml_kv "SerialPort" "${SERIAL_PORT}"
set_xml_kv "Baudrate" "${BAUDRATE}"
set_xml_kv "MqttHost" "${MQTT_HOST}"
set_xml_kv "MqttPort" "${MQTT_PORT}"

if [ -n "${MQTT_USER}" ] && [ "${MQTT_USER}" != "null" ]; then
  set_xml_kv "MqttUser" "${MQTT_USER}"
fi
if [ -n "${MQTT_PASS}" ] && [ "${MQTT_PASS}" != "null" ]; then
  set_xml_kv "MqttPassword" "${MQTT_PASS}"
fi

echo "-----------------------------------------"
echo "[DEBUG] CFG structural markers (line numbers):"
grep -n -E "<configuration>|</configuration>|<appSettings>|</appSettings>|<applicationSettings>|</applicationSettings>|<userSettings>|</userSettings>" "${CFG}" || true
echo "-----------------------------------------"
echo "[DEBUG] All <add ...> lines (password redacted):"
sed -E 's/(key="(MqttPassword|Password)" value=")[^"]*"/\1***"/g' "${CFG}" | grep -n "<add " || true
echo "-----------------------------------------"

echo "[INFO] Starting ComfoBoxMqttConsole..."
cd "${BASE_DIR}"
exec mono ./ComfoBoxMqttConsole.exe
