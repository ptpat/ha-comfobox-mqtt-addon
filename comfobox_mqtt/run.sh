#!/usr/bin/with-contenv bash
set -e

WAVESHARE_HOST="$(bashio::config 'waveshare_host')"
WAVESHARE_PORT="$(bashio::config 'waveshare_port')"
SERIAL_PORT="$(bashio::config 'serial_port')"
BAUDRATE="$(bashio::config 'baudrate')"

MQTT_HOST="$(bashio::config 'mqtt_host')"
MQTT_PORT="$(bashio::config 'mqtt_port')"
MQTT_USER="$(bashio::config 'mqtt_user')"
MQTT_PASS="$(bashio::config 'mqtt_pass')"

bashio::log.info "waveshare=${WAVESHARE_HOST}:${WAVESHARE_PORT} serial=${SERIAL_PORT} baud=${BAUDRATE} mqtt=${MQTT_HOST}:${MQTT_PORT}"

# 1) Optional socat: TCP->PTY (dein Waveshare)
if bashio::config.true 'use_socat'; then
  bashio::log.info "Starting socat..."
  socat -d -d pty,raw,echo=0,link="${SERIAL_PORT}" "tcp:${WAVESHARE_HOST}:${WAVESHARE_PORT}" &
fi

# 2) In den RF77-Ordner wechseln
cd /app/ComfoBox2Mqtt

# 3) Prüfen, ob exe + config da sind
if [ ! -f "ComfoBoxMqttConsole.exe" ] || [ ! -f "ComfoBoxMqttConsole.exe.config" ]; then
  bashio::log.error "RF77 files not found in /app/ComfoBox2Mqtt"
  ls -la /app
  ls -la /app/ComfoBox2Mqtt || true
  exit 1
fi

bashio::log.info "Starting ComfoBoxMqttConsole..."
exec mono ComfoBoxMqttConsole.exe
