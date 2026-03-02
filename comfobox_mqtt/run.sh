#!/usr/bin/env bash
set -euo pipefail

# Lese die Konfiguration aus den Add-on-Optionen
WAVESHARE_HOST="$(jq -r '.waveshare_host' /data/options.json)"
WAVESHARE_PORT="$(jq -r '.waveshare_port' /data/options.json)"
SERIAL_PORT="$(jq -r '.serial_port' /data/options.json)"
BAUDRATE="$(jq -r '.baudrate' /data/options.json)"
MQTT_HOST="$(jq -r '.mqtt_host' /data/options.json)"
MQTT_PORT="$(jq -r '.mqtt_port' /data/options.json)"
MQTT_USER="$(jq -r '.mqtt_user' /data/options.json)"
MQTT_PASS="$(jq -r '.mqtt_pass' /data/options.json)"
USE_SOCAT="$(jq -r '.use_socat' /data/options.json)"

if [ "${USE_SOCAT}" = "true" ]; then
  echo "[INFO] Starte socat: tcp:${WAVESHARE_HOST}:${WAVESHARE_PORT} → ${SERIAL_PORT}"
  socat -d -d "pty,raw,echo=0,link=${SERIAL_PORT}" "tcp:${WAVESHARE_HOST}:${WAVESHARE_PORT}" &
  sleep 2
fi

echo "[INFO] Starte ComfoBox-MQTT..."
mono /app/ComfoBoxMqttConsole.exe
