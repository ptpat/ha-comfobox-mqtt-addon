#!/usr/bin/env bash
set -euo pipefail

# Options aus HA Add-on config
WAVESHARE_HOST="$(jq -r '.waveshare_host' /data/options.json)"
WAVESHARE_PORT="$(jq -r '.waveshare_port' /data/options.json)"
SERIAL_PORT="$(jq -r '.serial_port' /data/options.json)"
BAUDRATE="$(jq -r '.baudrate' /data/options.json)"
MQTT_HOST="$(jq -r '.mqtt_host' /data/options.json)"
MQTT_PORT="$(jq -r '.mqtt_port' /data/options.json)"
MQTT_USER="$(jq -r '.mqtt_user' /data/options.json)"
MQTT_PASS="$(jq -r '.mqtt_pass' /data/options.json)"
USE_SOCAT="$(jq -r '.use_socat' /data/options.json)"

echo "[INFO] waveshare=${WAVESHARE_HOST}:${WAVESHARE_PORT} serial=${SERIAL_PORT} baud=${BAUDRATE} mqtt=${MQTT_HOST}:${MQTT_PORT}"

# 1) TCP -> virtueller Serial Port
if [ "${USE_SOCAT}" = "true" ]; then
  echo "[INFO] Starting socat..."
  socat -d -d "pty,raw,echo=0,link=${SERIAL_PORT}" "tcp:${WAVESHARE_HOST}:${WAVESHARE_PORT}" &
  sleep 2
fi

# 2) Config-Datei patchen (XML config)
CFG="ComfoBoxMqttConsole.exe.config"

if [ ! -f "${CFG}" ]; then
  echo "[ERROR] ${CFG} not found in /app"
  ls -la
  exit 1
fi

# SerialPort setzen
sed -i "s|<add key=\"SerialPort\" value=\"[^\"]*\" />|<add key=\"SerialPort\" value=\"${SERIAL_PORT}\" />|g" "${CFG}"
# Baudrate setzen
sed -i "s|<add key=\"Baudrate\" value=\"[^\"]*\" />|<add key=\"Baudrate\" value=\"${BAUDRATE}\" />|g" "${CFG}"
# MQTT Host/Port setzen
sed -i "s|<add key=\"MqttHost\" value=\"[^\"]*\" />|<add key=\"MqttHost\" value=\"${MQTT_HOST}\" />|g" "${CFG}"
sed -i "s|<add key=\"MqttPort\" value=\"[^\"]*\" />|<add key=\"MqttPort\" value=\"${MQTT_PORT}\" />|g" "${CFG}"

# MQTT User/Pass optional (nur setzen wenn nicht leer)
if [ -n "${MQTT_USER}" ] && [ "${MQTT_USER}" != "null" ]; then
  sed -i "s|<add key=\"MqttUser\" value=\"[^\"]*\" />|<add key=\"MqttUser\" value=\"${MQTT_USER}\" />|g" "${CFG}"
fi
if [ -n "${MQTT_PASS}" ] && [ "${MQTT_PASS}" != "null" ]; then
  sed -i "s|<add key=\"MqttPassword\" value=\"[^\"]*\" />|<add key=\"MqttPassword\" value=\"${MQTT_PASS}\" />|g" "${CFG}"
fi

# 3) Start
echo "[INFO] Starting ComfoBoxMqttConsole..."
exec mono /app/ComfoBoxMqttConsole.exe
