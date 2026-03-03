#!/usr/bin/with-contenv bash
set -euo pipefail

echo "[INFO] run.sh (options.json + socat + RF77 config patch + mono) starting"

OPTIONS_FILE="/data/options.json"

# ---------- helpers ----------
get_opt() {
  local key="$1"
  local def="${2:-}"
  if [[ -f "$OPTIONS_FILE" ]]; then
    # returns "null" if missing; convert to empty
    local val
    val="$(jq -r --arg k "$key" '.[$k] // empty' "$OPTIONS_FILE" 2>/dev/null || true)"
    if [[ -n "$val" ]]; then
      echo "$val"
      return 0
    fi
  fi
  echo "$def"
}

redact() {
  local s="$1"
  if [[ -z "$s" ]]; then
    echo ""
  else
    echo "***"
  fi
}

# ---------- read options ----------
USE_SOCAT="$(get_opt use_socat "true")"
WAVESHARE_HOST="$(get_opt waveshare_host "")"
WAVESHARE_PORT="$(get_opt waveshare_port "0")"
SERIAL_PORT="$(get_opt serial_port "/tmp/comfobox")"
BAUDRATE="$(get_opt baudrate "38400")"

MQTT_HOST="$(get_opt mqtt_host "core-mosquitto")"
MQTT_PORT="$(get_opt mqtt_port "1883")"
MQTT_USER="$(get_opt mqtt_user "")"
MQTT_PASS="$(get_opt mqtt_pass "")"

echo "[INFO] waveshare=${WAVESHARE_HOST}:${WAVESHARE_PORT}"
echo "[INFO] serial=${SERIAL_PORT} baud=${BAUDRATE}"
echo "[INFO] mqtt=${MQTT_HOST}:${MQTT_PORT} user_set=$([[ -n "$MQTT_USER" ]] && echo yes || echo no)"

# ---------- locate RF77 console ----------
APPDIR="/app"
EXE_REL="ComfoBox2Mqtt/ComfoBoxMqttConsole.exe"
CFG_REL="ComfoBox2Mqtt/ComfoBoxMqttConsole.exe.config"

if [[ ! -f "${APPDIR}/${EXE_REL}" ]]; then
  echo "[ERROR] ${EXE_REL} not found in /app. Listing /app:"
  ls -la /app || true
  echo "[INFO] Shutting down..."
  exit 1
fi

if [[ ! -f "${APPDIR}/${CFG_REL}" ]]; then
  echo "[ERROR] ${CFG_REL} not found in /app/ComfoBox2Mqtt"
  ls -la /app/ComfoBox2Mqtt || true
  echo "[INFO] Shutting down..."
  exit 1
fi

echo "[INFO] Found console in: /app/ComfoBox2Mqtt"

# ---------- socat PTY -> TCP (Waveshare) ----------
SOCAT_PID=""
PTY_CREATED="false"

if [[ "${USE_SOCAT}" == "true" ]]; then
  if [[ -z "${WAVESHARE_HOST}" || "${WAVESHARE_PORT}" == "0" ]]; then
    echo "[ERROR] use_socat=true but waveshare_host/port not set"
    echo "[INFO] Shutting down..."
    exit 1
  fi

  echo "[INFO] Starting socat (PTY -> TCP ${WAVESHARE_HOST}:${WAVESHARE_PORT})..."
  # Create PTY and link it to SERIAL_PORT
  # NOTE: Socat prints the PTY path, but we don't need to parse it if we link with 'link='.
  socat -d -d \
    pty,raw,echo=0,link="${SERIAL_PORT}",mode=666 \
    "tcp:${WAVESHARE_HOST}:${WAVESHARE_PORT}" \
    &
  SOCAT_PID="$!"
  PTY_CREATED="true"

  # Small delay so link exists
  sleep 1
  echo "[DEBUG] serial link:"
  ls -la "${SERIAL_PORT}" || true
fi

# ---------- patch config (safe) ----------
CFG_PATH="${APPDIR}/${CFG_REL}"
CFG_BAK="${CFG_PATH}.bak"

echo "[INFO] Patching RF77 config: ${CFG_PATH}"
cp -f "${CFG_PATH}" "${CFG_BAK}"

# We patch both:
# 1) <appSettings> keys (some builds read these)
# 2) <applicationSettings> values (your log showed MQTT broker there too)

# Ensure <configSections> remains first element under <configuration>.
# We'll rebuild <appSettings> block cleanly and keep the rest as-is.

tmp="$(mktemp)"

awk -v serial="${SERIAL_PORT}" \
    -v baud="${BAUDRATE}" \
    -v mh="${MQTT_HOST}" \
    -v mp="${MQTT_PORT}" \
    -v mu="${MQTT_USER}" \
    -v mw="${MQTT_PASS}" '
BEGIN { in_app=0; printed_app=0; }
{
  # skip any existing appSettings block; we replace it once
  if ($0 ~ /<appSettings>/) { in_app=1; next; }
  if (in_app==1 && $0 ~ /<\/appSettings>/) { in_app=0; next; }
  if (in_app==1) { next; }

  # After </configSections> (or if none, after <configuration>) insert appSettings once.
  if (!printed_app) {
    if ($0 ~ /<\/configSections>/) {
      print $0;
      print "  <appSettings>";
      print "    <add key=\"SerialPort\" value=\"" serial "\" />";
      print "    <add key=\"Baudrate\" value=\"" baud "\" />";
      print "    <add key=\"MqttHost\" value=\"" mh "\" />";
      print "    <add key=\"MqttPort\" value=\"" mp "\" />";
      print "    <add key=\"MqttUser\" value=\"" mu "\" />";
      print "    <add key=\"MqttPassword\" value=\"" mw "\" />";
      print "  </appSettings>";
      printed_app=1;
      next;
    }
    if ($0 ~ /<configuration>/) {
      print $0;
      next;
    }
  }

  print $0;
}
END {
  # if configSections didn’t exist, we didn’t inject; inject just before </configuration>
  # (handled by a second pass in shell if needed)
}
' "${CFG_BAK}" > "${tmp}"

# If appSettings not injected (no configSections), inject before </configuration>
if ! grep -q "<appSettings>" "${tmp}"; then
  tmp2="$(mktemp)"
  awk -v serial="${SERIAL_PORT}" \
      -v baud="${BAUDRATE}" \
      -v mh="${MQTT_HOST}" \
      -v mp="${MQTT_PORT}" \
      -v mu="${MQTT_USER}" \
      -v mw="${MQTT_PASS}" '
  {
    if ($0 ~ /<\/configuration>/) {
      print "  <appSettings>";
      print "    <add key=\"SerialPort\" value=\"" serial "\" />";
      print "    <add key=\"Baudrate\" value=\"" baud "\" />";
      print "    <add key=\"MqttHost\" value=\"" mh "\" />";
      print "    <add key=\"MqttPort\" value=\"" mp "\" />";
      print "    <add key=\"MqttUser\" value=\"" mu "\" />";
      print "    <add key=\"MqttPassword\" value=\"" mw "\" />";
      print "  </appSettings>";
    }
    print $0;
  }' "${tmp}" > "${tmp2}"
  mv -f "${tmp2}" "${tmp}"
fi

# Patch applicationSettings values we know are relevant:
# - Port
# - Baudrate
# - MqttBrokerAddress (RF77 used this in your debug output)
# Keep it simple: replace the <value> line right after matching <setting name="...">
tmp3="$(mktemp)"
awk -v serial="${SERIAL_PORT}" -v baud="${BAUDRATE}" -v mh="${MQTT_HOST}" '
BEGIN { want=""; }
{
  if ($0 ~ /<setting name="Port"/) { want="Port"; print; next; }
  if ($0 ~ /<setting name="Baudrate"/) { want="Baudrate"; print; next; }
  if ($0 ~ /<setting name="MqttBrokerAddress"/) { want="MqttBrokerAddress"; print; next; }

  if (want != "" && $0 ~ /<value>.*<\/value>/) {
    if (want=="Port")             { print "        <value>" serial "</value>"; }
    else if (want=="Baudrate")    { print "        <value>" baud "</value>"; }
    else if (want=="MqttBrokerAddress") { print "        <value>" mh "</value>"; }
    want="";
    next;
  }

  print;
}
' "${tmp}" > "${tmp3}"

mv -f "${tmp3}" "${CFG_PATH}"
rm -f "${tmp}"

echo "-----------------------------------------"
echo "[DEBUG] appSettings (password redacted):"
awk '
/<appSettings>/,/<\/appSettings>/ {
  line=$0
  gsub(/value="[^"]*"/,"value=\"***\"",line)  # blanket redact in this block
  # un-redact non-secret fields:
  gsub(/key="SerialPort" value="[*][*][*]"/,"key=\"SerialPort\" value=\"(set)\"",line)
  gsub(/key="Baudrate" value="[*][*][*]"/,"key=\"Baudrate\" value=\"(set)\"",line)
  gsub(/key="MqttHost" value="[*][*][*]"/,"key=\"MqttHost\" value=\"(set)\"",line)
  gsub(/key="MqttPort" value="[*][*][*]"/,"key=\"MqttPort\" value=\"(set)\"",line)
  gsub(/key="MqttUser" value="[*][*][*]"/,"key=\"MqttUser\" value=\"(set)\"",line)
  print line
}' "${CFG_PATH}" || true
echo "-----------------------------------------"

echo "[INFO] Starting ComfoBoxMqttConsole..."
cd "${APPDIR}"
exec mono "${EXE_REL}"
