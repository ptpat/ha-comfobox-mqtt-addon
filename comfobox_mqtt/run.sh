#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] run.sh v2 (RF77 config patch + socat + mono) starting"

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

# ---- Basic validation ----
if [ -z "${WAVESHARE_HOST}" ] || [ "${WAVESHARE_HOST}" = "null" ]; then
  echo "[ERROR] waveshare_host is empty. Set it in the add-on configuration."
  exit 1
fi
if [ -z "${WAVESHARE_PORT}" ] || [ "${WAVESHARE_PORT}" = "null" ] || [ "${WAVESHARE_PORT}" = "0" ]; then
  echo "[ERROR] waveshare_port is empty/0. Set it in the add-on configuration."
  exit 1
fi
if [ -z "${MQTT_HOST}" ] || [ "${MQTT_HOST}" = "null" ]; then
  echo "[ERROR] mqtt_host is empty. Set it in the add-on configuration."
  exit 1
fi
if [ -z "${MQTT_PORT}" ] || [ "${MQTT_PORT}" = "null" ] || [ "${MQTT_PORT}" = "0" ]; then
  echo "[ERROR] mqtt_port is empty/0. Set it in the add-on configuration."
  exit 1
fi

echo "[INFO] waveshare=${WAVESHARE_HOST}:${WAVESHARE_PORT} serial=${SERIAL_PORT} baud=${BAUDRATE}"
echo "[INFO] mqtt=${MQTT_HOST}:${MQTT_PORT} user_set=$([ -n "${MQTT_USER}" ] && [ "${MQTT_USER}" != "null" ] && echo yes || echo no)"

# ---- Start socat (TCP->PTY) ----
if [ "${USE_SOCAT}" = "true" ]; then
  echo "[INFO] Starting socat..."
  socat -d -d "pty,raw,echo=0,link=${SERIAL_PORT}" "tcp:${WAVESHARE_HOST}:${WAVESHARE_PORT}" &
  sleep 2
else
  echo "[INFO] use_socat=false (skipping socat)"
fi

# ---- Locate RF77 console ----
BASE_DIR="/app/ComfoBox2Mqtt"
EXE="${BASE_DIR}/ComfoBoxMqttConsole.exe"
CFG="${BASE_DIR}/ComfoBoxMqttConsole.exe.config"

if [ ! -d "${BASE_DIR}" ]; then
  echo "[ERROR] ${BASE_DIR} not found. Listing /app:"
  ls -la /app || true
  exit 1
fi
if [ ! -f "${EXE}" ]; then
  echo "[ERROR] ${EXE} not found. Listing ${BASE_DIR}:"
  ls -la "${BASE_DIR}" || true
  exit 1
fi
if [ ! -f "${CFG}" ]; then
  echo "[ERROR] ${CFG} not found. Listing ${BASE_DIR}:"
  ls -la "${BASE_DIR}" || true
  exit 1
fi

echo "[INFO] Patching RF77 config: ${CFG}"

# ---- Helper: ensure <add key="X" value="Y" /> exists and set ----
set_xml_kv() {
  local key="$1"
  local val="$2"

  if grep -q "key=\"${key}\"" "${CFG}"; then
    sed -i "s|<add key=\"${key}\" value=\"[^\"]*\" />|<add key=\"${key}\" value=\"${val}\" />|g" "${CFG}"
  else
    # insert before closing </appSettings>
    sed -i "s|</appSettings>|  <add key=\"${key}\" value=\"${val}\" />\n</appSettings>|" "${CFG}"
  fi
}

# Serial settings
set_xml_kv "SerialPort" "${SERIAL_PORT}"
set_xml_kv "Baudrate" "${BAUDRATE}"

# MQTT settings
set_xml_kv "MqttHost" "${MQTT_HOST}"
set_xml_kv "MqttPort" "${MQTT_PORT}"

# Optional credentials (only if set)
if [ -n "${MQTT_USER}" ] && [ "${MQTT_USER}" != "null" ]; then
  set_xml_kv "MqttUser" "${MQTT_USER}"
fi
if [ -n "${MQTT_PASS}" ] && [ "${MQTT_PASS}" != "null" ]; then
  set_xml_kv "MqttPassword" "${MQTT_PASS}"
fi

echo "[INFO] Starting ComfoBoxMqttConsole..."
cd "${BASE_DIR}"
exec mono ./ComfoBoxMqttConsole.exe
