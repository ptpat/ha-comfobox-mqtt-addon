#!/usr/bin/with-contenv bash
set -euo pipefail

echo "[INFO] run.sh baseline (bashio + socat PTY without link= + patch + mono) starting"

USE_SOCAT="$(bashio::config 'use_socat' || echo 'true')"
WAVESHARE_HOST="$(bashio::config 'waveshare_host' || echo '')"
WAVESHARE_PORT="$(bashio::config 'waveshare_port' || echo '0')"

SERIAL_PORT="$(bashio::config 'serial_port' || echo '/tmp/comfobox')"
BAUDRATE="$(bashio::config 'baudrate' || echo '38400')"

MQTT_HOST="$(bashio::config 'mqtt_host' || echo 'core-mosquitto')"
MQTT_PORT="$(bashio::config 'mqtt_port' || echo '1883')"
MQTT_USER="$(bashio::config 'mqtt_user' || echo '')"
MQTT_PASS="$(bashio::config 'mqtt_pass' || echo '')"
MQTT_BASE_TOPIC="$(bashio::config 'mqtt_base_topic' || echo 'ComfoBox')"

BACNET_MASTER_ID="$(bashio::config 'bacnet_master_id' || echo '1')"
BACNET_CLIENT_ID="$(bashio::config 'bacnet_client_id' || echo '3')"

USER_SET="no"
if [[ -n "${MQTT_USER}" ]]; then USER_SET="yes"; fi

echo "[INFO] waveshare=${WAVESHARE_HOST}:${WAVESHARE_PORT}"
echo "[INFO] serial=${SERIAL_PORT} baud=${BAUDRATE}"
echo "[INFO] mqtt=${MQTT_HOST}:${MQTT_PORT} user_set=${USER_SET}"
echo "[INFO] mqtt_base_topic=${MQTT_BASE_TOPIC}"
echo "[INFO] bacnet_master_id=${BACNET_MASTER_ID} bacnet_client_id=${BACNET_CLIENT_ID}"

APPDIR="/app"
CONSOLE_DIR=""

if [[ -f "${APPDIR}/rf77/ComfoBox2Mqtt/ComfoBoxMqttConsole.exe" ]]; then
  CONSOLE_DIR="${APPDIR}/rf77/ComfoBox2Mqtt"
elif [[ -f "${APPDIR}/ComfoBox2Mqtt/ComfoBoxMqttConsole.exe" ]]; then
  CONSOLE_DIR="${APPDIR}/ComfoBox2Mqtt"
elif [[ -f "${APPDIR}/ComfoBoxMqttConsole.exe" ]]; then
  CONSOLE_DIR="${APPDIR}"
else
  echo "[ERROR] ComfoBoxMqttConsole.exe not found. Listing /app:"
  ls -lah "${APPDIR}" || true
  exit 1
fi

echo "[INFO] Found console in: ${CONSOLE_DIR}"
CFG="${CONSOLE_DIR}/ComfoBoxMqttConsole.exe.config"

if [[ ! -f "${CFG}" ]]; then
  echo "[ERROR] ${CFG} not found"
  ls -lah "${CONSOLE_DIR}" || true
  exit 1
fi

SOCAT_PID=""

cleanup() {
  echo "[INFO] Shutting down..."
  if [[ -n "${SOCAT_PID}" ]]; then
    kill "${SOCAT_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Start socat and create /tmp/comfobox symlink ourselves (no socat link=)
if [[ "${USE_SOCAT}" == "true" ]]; then
  if [[ -z "${WAVESHARE_HOST}" || "${WAVESHARE_PORT}" == "0" ]]; then
    echo "[ERROR] use_socat=true but waveshare_host/port not set"
    exit 1
  fi

  echo "[INFO] Starting socat (TCP -> PTY)..."
  SOCAT_LOG="/tmp/socat.log"
  rm -f "${SOCAT_LOG}" || true

  # Run socat in background; capture stderr to file so we can extract PTY
  (socat -d -d \
      "TCP:${WAVESHARE_HOST}:${WAVESHARE_PORT},keepalive,nodelay" \
      "PTY,rawer,echo=0,waitslave" \
    2> >(tee "${SOCAT_LOG}" >&2)) &

  SOCAT_PID="$!"

  # Wait for PTY path to appear
  PTY=""
  for _ in $(seq 1 50); do
    PTY="$(grep -Eo '/dev/pts/[0-9]+' "${SOCAT_LOG}" | head -n1 || true)"
    if [[ -n "${PTY}" && -c "${PTY}" ]]; then
      break
    fi
    sleep 0.1
  done

  if [[ -z "${PTY}" ]]; then
    echo "[ERROR] Could not detect PTY from socat log"
    tail -n 80 "${SOCAT_LOG}" || true
    exit 1
  fi

  echo "[INFO] Detected PTY: ${PTY}"
  echo "[INFO] Creating symlink: ${SERIAL_PORT} -> ${PTY}"
  rm -f "${SERIAL_PORT}" 2>/dev/null || true
  ln -sf "${PTY}" "${SERIAL_PORT}" || true
  ls -lah "${SERIAL_PORT}" || true
fi

echo "[INFO] Patching RF77 config: ${CFG}"

# Patch applicationSettings (ComfoBoxLib/ComfoBoxMqtt) – multiline-safe
patch_setting_value() {
  local name="$1"
  local val="$2"
  local file="$3"
  sed -i -E "/setting name=\"${name}\"/,/<\/setting>/ s|<value>[^<]*</value>|<value>${val}</value>|" "${file}" || true
}

patch_setting_value "Port" "${SERIAL_PORT}" "${CFG}"
patch_setting_value "Baudrate" "${BAUDRATE}" "${CFG}"
patch_setting_value "BacnetMasterId" "${BACNET_MASTER_ID}" "${CFG}"
patch_setting_value "BacnetClientId" "${BACNET_CLIENT_ID}" "${CFG}"
patch_setting_value "MqttBrokerAddress" "${MQTT_HOST}" "${CFG}"
patch_setting_value "BaseTopic" "${MQTT_BASE_TOPIC}" "${CFG}"
patch_setting_value "WriteTopicsToFile" "False" "${CFG}"

echo "[INFO] Starting ComfoBoxMqttConsole"
cd "${CONSOLE_DIR}"
exec mono "./ComfoBoxMqttConsole.exe"
