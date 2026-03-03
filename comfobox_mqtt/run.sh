#!/usr/bin/with-contenv bash
set -euo pipefail

echo "[INFO] run.sh v9 (options + socat + safe RF77 config patch) starting"

# --- Read HA add-on options (bashio is available when using HA base images) ---
USE_SOCAT="$(bashio::config 'use_socat' || echo 'true')"
WAVESHARE_HOST="$(bashio::config 'waveshare_host' || echo '')"
WAVESHARE_PORT="$(bashio::config 'waveshare_port' || echo '0')"
SERIAL_PORT="$(bashio::config 'serial_port' || echo '/tmp/comfobox')"
BAUDRATE="$(bashio::config 'baudrate' || echo '38400')"

MQTT_HOST="$(bashio::config 'mqtt_host' || echo 'core-mosquitto')"
MQTT_PORT="$(bashio::config 'mqtt_port' || echo '1883')"
MQTT_USER="$(bashio::config 'mqtt_user' || echo '')"
MQTT_PASS="$(bashio::config 'mqtt_pass' || echo '')"

USER_SET="no"
if [[ -n "${MQTT_USER}" ]]; then USER_SET="yes"; fi

echo "[INFO] waveshare=${WAVESHARE_HOST}:${WAVESHARE_PORT}"
echo "[INFO] serial=${SERIAL_PORT} baud=${BAUDRATE}"
echo "[INFO] mqtt=${MQTT_HOST}:${MQTT_PORT} user_set=${USER_SET}"

# --- Locate RF77 console ---
APPDIR="/app"
CONSOLE_DIR=""
if [[ -f "${APPDIR}/ComfoBox2Mqtt/ComfoBoxMqttConsole.exe" ]]; then
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

# --- Start socat PTY bridge (if enabled) ---
SOCAT_PID=""
PTY_PATH=""
cleanup() {
  echo "[INFO] Shutting down..."
  if [[ -n "${SOCAT_PID}" ]]; then
    kill "${SOCAT_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "${USE_SOCAT}" == "true" ]]; then
  if [[ -z "${WAVESHARE_HOST}" || "${WAVESHARE_PORT}" == "0" ]]; then
    echo "[ERROR] use_socat=true but waveshare_host/port not set"
    exit 1
  fi

  echo "[INFO] Starting socat (PTY -> TCP)..."
  # socat prints "PTY is /dev/pts/X" to stderr
  SOCAT_LOG="/tmp/socat.log"
  rm -f "${SOCAT_LOG}" || true

  # Create PTY and link it to SERIAL_PORT
  # NOTE: This PTY is the part that Mono often cannot handle (ioctl error).
  socat -d -d \
    "PTY,link=${SERIAL_PORT},rawer,echo=0" \
    "TCP:${WAVESHARE_HOST}:${WAVESHARE_PORT},keepalive,nodelay" \
    2> >(tee "${SOCAT_LOG}" >&2) &
  SOCAT_PID="$!"

  # Wait a moment for the PTY to be created
  sleep 1

  # Show link + PTY info
  if [[ -L "${SERIAL_PORT}" ]]; then
    echo "[DEBUG] serial link:"
    ls -lah "${SERIAL_PORT}" || true
  else
    echo "[WARN] ${SERIAL_PORT} is not a symlink (unexpected)."
    ls -lah "${SERIAL_PORT}" || true
  fi

  # Extract PTY path if possible
  PTY_PATH="$(grep -Eo 'PTY is /dev/pts/[0-9]+' "${SOCAT_LOG}" | tail -n1 | awk '{print $3}' || true)"
fi

# --- Patch RF77 config safely ---
# We patch BOTH:
# 1) <appSettings> keys (SerialPort, Baudrate, MqttHost/Port/User/Password)
# 2) <applicationSettings> keys (ComfoBoxLib.Properties.Settings: Port, Baudrate, MqttBrokerAddress)
#
# Keep <configSections> first; do NOT move it below appSettings.

echo "[INFO] Patching RF77 config: ${CFG}"

# Helper: XML-escape minimal (for password/user) - keep it simple
xml_escape() {
  local s="${1}"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  echo -n "${s}"
}

ES_MQTT_HOST="$(xml_escape "${MQTT_HOST}")"
ES_MQTT_PORT="$(xml_escape "${MQTT_PORT}")"
ES_MQTT_USER="$(xml_escape "${MQTT_USER}")"
ES_MQTT_PASS="$(xml_escape "${MQTT_PASS}")"
ES_SERIAL_PORT="$(xml_escape "${SERIAL_PORT}")"
ES_BAUDRATE="$(xml_escape "${BAUDRATE}")"

# 1) Ensure appSettings exists and contains our keys
#    We rebuild only the appSettings block to avoid malformed XML ordering.
awk -v sp="${ES_SERIAL_PORT}" -v br="${ES_BAUDRATE}" \
    -v mh="${ES_MQTT_HOST}" -v mp="${ES_MQTT_PORT}" \
    -v mu="${ES_MQTT_USER}" -v mw="${ES_MQTT_PASS}" '
BEGIN {
  in_app=0; wrote_app=0;
}
function print_appsettings() {
  print "  <appSettings>";
  print "    <add key=\"SerialPort\" value=\"" sp "\" />";
  print "    <add key=\"Baudrate\" value=\"" br "\" />";
  print "    <add key=\"MqttHost\" value=\"" mh "\" />";
  print "    <add key=\"MqttPort\" value=\"" mp "\" />";
  print "    <add key=\"MqttUser\" value=\"" mu "\" />";
  print "    <add key=\"MqttPassword\" value=\"" mw "\" />";
  print "  </appSettings>";
}
{
  # Skip existing appSettings block entirely
  if ($0 ~ /<appSettings>/) { in_app=1; next }
  if (in_app && $0 ~ /<\/appSettings>/) { in_app=0; next }
  if (in_app) { next }

  # After </configSections>, insert our appSettings once
  if (!wrote_app && $0 ~ /<\/configSections>/) {
    print $0;
    print_appsettings();
    wrote_app=1;
    next;
  }

  print $0;
}
END {
  # If there was no configSections at all, we never inserted -> append before </configuration>
  # (rare; but safe fallback)
}
' "${CFG}" > "${CFG}.tmp" && mv "${CFG}.tmp" "${CFG}"

# 2) Patch applicationSettings values if present (best effort)
# Update ComfoBoxLib.Properties.Settings: Baudrate + Port + MqttBrokerAddress
# NOTE: We do conservative in-place substitutions.
sed -i \
  -e "s#<setting name=\"Baudrate\" serializeAs=\"String\">[[:space:]\r\n]*<value>[^<]*</value>#[&]#g" \
  "${CFG}" || true

# Replace specific <value> lines after the setting name; do it with awk for stability
awk -v sp="${ES_SERIAL_PORT}" -v br="${ES_BAUDRATE}" -v mh="${ES_MQTT_HOST}" '
BEGIN { in_lib=0; in_set=""; }
{
  # Track whether we are inside ComfoBoxLib.Properties.Settings
  if ($0 ~ /<ComfoBoxLib\.Properties\.Settings>/) in_lib=1
  if ($0 ~ /<\/ComfoBoxLib\.Properties\.Settings>/) { in_lib=0; in_set="" }

  if (in_lib && match($0, /<setting name="([^"]+)"/, m)) {
    in_set=m[1]
  }

  if (in_lib && in_set=="Baudrate" && $0 ~ /<value>/) {
    sub(/<value>[^<]*<\/value>/, "<value>" br "</value>")
    in_set=""
  } else if (in_lib && in_set=="Port" && $0 ~ /<value>/) {
    sub(/<value>[^<]*<\/value>/, "<value>" sp "</value>")
    in_set=""
  } else if (in_lib && in_set=="MqttBrokerAddress" && $0 ~ /<value>/) {
    sub(/<value>[^<]*<\/value>/, "<value>" mh "</value>")
    in_set=""
  }

  print $0
}
' "${CFG}" > "${CFG}.tmp" && mv "${CFG}.tmp" "${CFG}"

# --- Debug print (redact password) ---
echo "-----------------------------------------"
echo "[DEBUG] appSettings (password redacted):"
grep -n "<appSettings>" -n "${CFG}" || true
grep -n "<add key=" "${CFG}" | sed -E 's/(MqttPassword" value=")[^"]*/\1***/' || true
echo "-----------------------------------------"
echo "[DEBUG] applicationSettings (relevant lines):"
grep -n "setting name=\"Baudrate\"" -n "${CFG}" || true
grep -n "setting name=\"Port\"" -n "${CFG}" || true
grep -n "setting name=\"MqttBrokerAddress\"" -n "${CFG}" || true
echo "-----------------------------------------"

# --- Start RF77 ---
echo "[INFO] Starting ComfoBoxMqttConsole..."
cd "${CONSOLE_DIR}"

set +e
mono ComfoBoxMqttConsole.exe
RC=$?
set -e

# If Mono died with the typical PTY ioctl error, print a clear hint.
if grep -q "Inappropriate ioctl for device" "${SUPERVISOR_LOGS:-/dev/null}" 2>/dev/null; then
  true
fi

if [[ "${RC}" -ne 0 ]]; then
  echo "[ERROR] ComfoBoxMqttConsole exited with code ${RC}"
  echo "[HINT] If you see 'Inappropriate ioctl for device', this is a known Mono + pseudo-tty limitation."
  echo "[HINT] Fix path A: Use a real /dev/ttyUSB* (USB-RS485) instead of socat PTY."
  echo "[HINT] Fix path B: Replace RF77/Mono with a native TCP->MQTT implementation."
fi

exit "${RC}"
