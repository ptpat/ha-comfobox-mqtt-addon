#!/bin/sh
set -eu

echo "[INFO] run.sh v10 (options.json + socat + RF77 config patch) starting"

OPTIONS="/data/options.json"

# Helper: read JSON key with jq (with default)
json_get() {
  key="$1"
  def="${2:-}"
  if [ -f "$OPTIONS" ]; then
    # returns empty if null/missing
    val="$(jq -r "$key // empty" "$OPTIONS" 2>/dev/null || true)"
    if [ -n "$val" ]; then
      echo "$val"
      return 0
    fi
  fi
  echo "$def"
}

use_socat="$(json_get '.use_socat' 'true')"
waveshare_host="$(json_get '.waveshare_host' '')"
waveshare_port="$(json_get '.waveshare_port' '0')"
serial_port="$(json_get '.serial_port' '/tmp/comfobox')"
baudrate="$(json_get '.baudrate' '38400')"

mqtt_host="$(json_get '.mqtt_host' 'core-mosquitto')"
mqtt_port="$(json_get '.mqtt_port' '1883')"
mqtt_user="$(json_get '.mqtt_user' '')"
mqtt_pass="$(json_get '.mqtt_pass' '')"

user_set="no"
if [ -n "$mqtt_user" ]; then user_set="yes"; fi

echo "[INFO] use_socat=$use_socat"
echo "[INFO] waveshare=${waveshare_host}:${waveshare_port}"
echo "[INFO] serial=${serial_port} baud=${baudrate}"
echo "[INFO] mqtt=${mqtt_host}:${mqtt_port} user_set=${user_set}"

# Locate RF77 console folder
APPDIR="/app/ComfoBox2Mqtt"
EXE="${APPDIR}/ComfoBoxMqttConsole.exe"
CFG="${APPDIR}/ComfoBoxMqttConsole.exe.config"

if [ ! -f "$EXE" ]; then
  echo "[ERROR] ComfoBoxMqttConsole.exe not found at $EXE"
  echo "[INFO] Listing /app:"
  ls -la /app || true
  exit 1
fi

if [ ! -f "$CFG" ]; then
  echo "[ERROR] RF77 config not found at $CFG"
  ls -la "$APPDIR" || true
  exit 1
fi

# Start socat if enabled
SOCAT_PID=""
if [ "$use_socat" = "true" ] || [ "$use_socat" = "1" ]; then
  if [ -z "$waveshare_host" ] || [ "$waveshare_port" = "0" ]; then
    echo "[ERROR] use_socat=true but waveshare_host/port not set"
    exit 1
  fi

  echo "[INFO] Starting socat (PTY -> TCP ${waveshare_host}:${waveshare_port})..."
  # Create a stable symlink (serial_port) -> PTY created by socat
  # socat prints PTY path to stdout; we capture it.
  PTY_PATH="$(socat -d -d pty,raw,echo=0,link="$serial_port" "tcp:${waveshare_host}:${waveshare_port}" 2>&1 \
    | sed -n 's/.*PTY is \(\/dev\/pts\/[0-9]*\).*/\1/p' | head -n 1 || true)"

  # Run socat in background (second instance) to keep it alive
  socat pty,raw,echo=0,link="$serial_port" "tcp:${waveshare_host}:${waveshare_port}" &
  SOCAT_PID="$!"
  sleep 1

  echo "[DEBUG] serial link:"
  ls -la "$serial_port" || true
else
  echo "[INFO] use_socat=false -> expecting real serial device at ${serial_port}"
fi

# Patch RF77 config (keep XML well-formed; only replace values)
echo "[INFO] Patching RF77 config: $CFG"

# Patch <applicationSettings> values that RF77 actually uses
# (MqttBrokerAddress / Port / Baudrate)
sed -i \
  -e "s#<setting name=\"MqttBrokerAddress\" serializeAs=\"String\">[[:space:]]*<value>[^<]*</value>#<setting name=\"MqttBrokerAddress\" serializeAs=\"String\"><value>${mqtt_host}</value>#g" \
  -e "s#<setting name=\"Port\" serializeAs=\"String\">[[:space:]]*<value>[^<]*</value>#<setting name=\"Port\" serializeAs=\"String\"><value>${serial_port}</value>#g" \
  -e "s#<setting name=\"Baudrate\" serializeAs=\"String\">[[:space:]]*<value>[^<]*</value>#<setting name=\"Baudrate\" serializeAs=\"String\"><value>${baudrate}</value>#g" \
  "$CFG" || true

# Patch <appSettings> keys (some RF77 builds read these)
# Ensure appSettings exists, but DO NOT reorder configSections etc.
if ! grep -q "<appSettings>" "$CFG"; then
  # Insert empty appSettings right after </configSections> if possible, else after <configuration>
  if grep -q "</configSections>" "$CFG"; then
    awk '
      {print}
      /<\/configSections>/ && !x {print "  <appSettings>\n  </appSettings>"; x=1}
    ' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
  else
    awk '
      /<configuration>/ && !x {print; print "  <appSettings>\n  </appSettings>"; x=1; next}
      {print}
    ' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
  fi
fi

# Replace or add keys inside appSettings
# (simple approach: delete existing keys and re-add)
# Remove existing lines for our keys
sed -i \
  -e '/<add key="SerialPort" /d' \
  -e '/<add key="Baudrate" /d' \
  -e '/<add key="MqttHost" /d' \
  -e '/<add key="MqttPort" /d' \
  -e '/<add key="MqttUser" /d' \
  -e '/<add key="MqttPassword" /d' \
  "$CFG"

# Insert our keys right after <appSettings>
awk -v sp="$serial_port" -v br="$baudrate" -v mh="$mqtt_host" -v mp="$mqtt_port" -v mu="$mqtt_user" -v pw="$mqtt_pass" '
  {print}
  /<appSettings>/ && !x {
    print "    <add key=\"SerialPort\" value=\"" sp "\" />"
    print "    <add key=\"Baudrate\" value=\"" br "\" />"
    print "    <add key=\"MqttHost\" value=\"" mh "\" />"
    print "    <add key=\"MqttPort\" value=\"" mp "\" />"
    if (mu != "") print "    <add key=\"MqttUser\" value=\"" mu "\" />"
    if (pw != "") print "    <add key=\"MqttPassword\" value=\"" pw "\" />"
    x=1
  }
' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"

echo "[INFO] Starting ComfoBoxMqttConsole..."
cd "$APPDIR"
exec mono "$EXE"
