#!/usr/bin/with-contenv bash
set -euo pipefail

echo "[INFO] run.sh (stable) starting"

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

echo "[INFO] use_socat=${USE_SOCAT}"
echo "[INFO] waveshare=${WAVESHARE_HOST}:${WAVESHARE_PORT}"
echo "[INFO] serial=${SERIAL_PORT} baud=${BAUDRATE}"
echo "[INFO] mqtt=${MQTT_HOST}:${MQTT_PORT} user_set=${USER_SET}"

CONSOLE_DIR="/app/ComfoBox2Mqtt"
CFG="${CONSOLE_DIR}/ComfoBoxMqttConsole.exe.config"

if [[ ! -f "${CONSOLE_DIR}/ComfoBoxMqttConsole.exe" ]]; then
  echo "[ERROR] ComfoBoxMqttConsole.exe not found in ${CONSOLE_DIR}"
  ls -la /app || true
  exit 1
fi

# Socat: Waveshare TCP -> PTY -> /tmp/comfobox symlink (wie bei hacomfoairmqtt)
SOCAT_PID=""
if [[ "${USE_SOCAT}" == "true" ]]; then
  if [[ -z "${WAVESHARE_HOST}" || -z "${WAVESHARE_PORT}" ]]; then
    echo "[ERROR] use_socat=true but waveshare_host/port not set"
    exit 1
  fi

  echo "[INFO] Starting socat..."
  rm -f "${SERIAL_PORT}" || true

  # PTY als "echtes" TTY anlegen und als Link unter SERIAL_PORT verfügbar machen
  socat -d -d -ly \
    pty,raw,echo=0,link="${SERIAL_PORT}",mode=666 \
    "tcp:${WAVESHARE_HOST}:${WAVESHARE_PORT}" &
  SOCAT_PID="$!"
  sleep 1

  if [[ ! -e "${SERIAL_PORT}" ]]; then
    echo "[ERROR] socat did not create ${SERIAL_PORT}"
    exit 1
  fi
fi

echo "[INFO] Patching RF77 config: ${CFG}"

# Minimal-invasive Patch: configSections muss VOR appSettings stehen -> wir ändern nur Werte, nicht Struktur.
# 1) Serial/Baud
sed -i \
  -e "s#<setting name=\"Baudrate\" serializeAs=\"String\">[[:space:]]*<value>[^<]*</value>#<setting name=\"Baudrate\" serializeAs=\"String\">\n        <value>${BAUDRATE}</value>#g" \
  -e "s#<setting name=\"Port\" serializeAs=\"String\">[[:space:]]*<value>[^<]*</value>#<setting name=\"Port\" serializeAs=\"String\">\n        <value>${SERIAL_PORT}</value>#g" \
  "${CFG}" || true

# 2) MQTT Broker Address in applicationSettings (das ist bei dir aktuell "localhost")
sed -i \
  -e "s#<setting name=\"MqttBrokerAddress\" serializeAs=\"String\">[[:space:]]*<value>[^<]*</value>#<setting name=\"MqttBrokerAddress\" serializeAs=\"String\">\n        <value>${MQTT_HOST}</value>#g" \
  "${CFG}" || true

# 3) appSettings: Host/Port/User/Pass (nur falls appSettings existiert)
if grep -q "<appSettings>" "${CFG}"; then
  # Host
  if grep -q 'key="MqttHost"' "${CFG}"; then
    sed -i -e "s#<add key=\"MqttHost\" value=\"[^\"]*\" />#<add key=\"MqttHost\" value=\"${MQTT_HOST}\" />#g" "${CFG}"
  fi
  # Port
  if grep -q 'key="MqttPort"' "${CFG}"; then
    sed -i -e "s#<add key=\"MqttPort\" value=\"[^\"]*\" />#<add key=\"MqttPort\" value=\"${MQTT_PORT}\" />#g" "${CFG}"
  fi
  # User
  if grep -q 'key="MqttUser"' "${CFG}"; then
    sed -i -e "s#<add key=\"MqttUser\" value=\"[^\"]*\" />#<add key=\"MqttUser\" value=\"${MQTT_USER}\" />#g" "${CFG}"
  fi
  # Pass
  if grep -q 'key="MqttPassword"' "${CFG}"; then
    # Passwort kann Sonderzeichen enthalten -> sed mit # Delimiter
    sed -i -e "s#<add key=\"MqttPassword\" value=\"[^\"]*\" />#<add key=\"MqttPassword\" value=\"${MQTT_PASS}\" />#g" "${CFG}"
  fi
fi

echo "[INFO] Starting ComfoBoxMqttConsole..."
cd "${CONSOLE_DIR}"
exec mono ComfoBoxMqttConsole.exe
