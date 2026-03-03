#!/usr/bin/env bash
set -euo pipefail

WAVESHARE_HOST="$(jq -r '.waveshare_host' /data/options.json)"
WAVESHARE_PORT="$(jq -r '.waveshare_port' /data/options.json)"
SERIAL_PORT="$(jq -r '.serial_port' /data/options.json)"
BAUDRATE="$(jq -r '.baudrate' /data/options.json)"
MQTT_HOST="$(jq -r '.mqtt_host' /data/options.json)"
MQTT_PORT="$(jq -r '.mqtt_port' /data/options.json)"
USE_SOCAT="$(jq -r '.use_socat' /data/options.json)"

echo "[INFO] waveshare=${WAVESHARE_HOST}:${WAVESHARE_PORT} serial=${SERIAL_PORT} baud=${BAUDRATE} mqtt=${MQTT_HOST}:${MQTT_PORT}"

if [ "${USE_SOCAT}" = "true" ]; then
  echo "[INFO] Starting socat..."
  socat -d -d "pty,raw,echo=0,link=${SERIAL_PORT}" "tcp:${WAVESHARE_HOST}:${WAVESHARE_PORT}" &
  sleep 2
fi

echo "[INFO] Looking for ComfoBoxMqttConsole.exe..."
EXE_PATH="$(find / -maxdepth 4 -type f -name 'ComfoBoxMqttConsole.exe' 2>/dev/null | head -n 1 || true)"

if [ -z "${EXE_PATH}" ]; then
  echo "[ERROR] ComfoBoxMqttConsole.exe not found. Listing /app:"
  ls -la /app || true
  exit 1
fi

BASE_DIR="$(dirname "${EXE_PATH}")"
echo "[INFO] Found console in: ${BASE_DIR}"

cd "${BASE_DIR}"
echo "[INFO] Starting ComfoBoxMqttConsole..."
exec mono ./ComfoBoxMqttConsole.exe
