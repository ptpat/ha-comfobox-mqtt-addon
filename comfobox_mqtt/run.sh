#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] ComfoBox MQTT Bridge starting..."

# ── Konfiguration aus HA options.json lesen ──────────────────────────────────
OPTIONS_JSON="/data/options.json"

get_opt() {
    local key="$1"
    local def="${2:-}"
    local val
    val="$(jq -r --arg k "$key" '.[$k] // empty' "$OPTIONS_JSON" 2>/dev/null || true)"
    if [ -n "$val" ] && [ "$val" != "null" ]; then
        echo "$val"
    else
        echo "$def"
    fi
}

WAVESHARE_HOST="$(get_opt waveshare_host "")"
WAVESHARE_PORT="$(get_opt waveshare_port "0")"
BAUDRATE="$(get_opt baudrate "76800")"
MQTT_HOST="$(get_opt mqtt_host "core-mosquitto")"
MQTT_PORT="$(get_opt mqtt_port "1883")"
MQTT_USER="$(get_opt mqtt_user "")"
MQTT_PASS="$(get_opt mqtt_pass "")"
MQTT_BASE_TOPIC="$(get_opt mqtt_base_topic "ComfoBox")"
BACNET_MASTER_ID="$(get_opt bacnet_master_id "1")"
BACNET_CLIENT_ID="$(get_opt bacnet_client_id "3")"
SERIAL_PTY="/tmp/comfobox"

echo "[INFO] Waveshare:    ${WAVESHARE_HOST}:${WAVESHARE_PORT}"
echo "[INFO] Baudrate:     ${BAUDRATE}"
echo "[INFO] MQTT:         ${MQTT_HOST}:${MQTT_PORT}"
echo "[INFO] MQTT topic:   ${MQTT_BASE_TOPIC}"
echo "[INFO] BACnet:       master=${BACNET_MASTER_ID} client=${BACNET_CLIENT_ID}"

# ── Validierung ───────────────────────────────────────────────────────────────
if [ -z "$WAVESHARE_HOST" ] || [ "$WAVESHARE_PORT" = "0" ]; then
    echo "[ERROR] waveshare_host und waveshare_port müssen konfiguriert sein!"
    exit 1
fi

# ── ZIP entpacken ─────────────────────────────────────────────────────────────
ZIP="/app/ComfoBox2Mqtt_0.4.0.zip"
if [ ! -f "$ZIP" ]; then
    echo "[ERROR] ZIP nicht gefunden: $ZIP"
    exit 1
fi

rm -rf /app/rf77
mkdir -p /app/rf77
unzip -o "$ZIP" -d /app/rf77 >/dev/null

EXE_PATH="$(find /app/rf77 -type f -name "ComfoBoxMqttConsole.exe" | head -n1 || true)"
if [ -z "$EXE_PATH" ]; then
    echo "[ERROR] ComfoBoxMqttConsole.exe nicht gefunden nach dem Entpacken"
    find /app/rf77 -maxdepth 6 -print || true
    exit 1
fi

APPDIR="$(dirname "$EXE_PATH")"
echo "[INFO] EXE gefunden: $EXE_PATH"

# ── RF77 Config-Dateien patchen ───────────────────────────────────────────────
# Die ZIP enthält eine einzelne zusammengeführte .config Datei.
# Setting-Namen gemäss tatsächlicher ZIP-Config:
#   ComfoBoxLib.Properties.Settings:  Port, Baudrate, BacnetClientId, BacnetMasterId,
#                                     MqttBrokerAddress (Singular, einfacher String!)
#   ComfoBoxMqtt.Properties.Settings: BaseTopic, WriteTopicsToFile

patch_xml_value() {
    # Patcht <setting name="KEY"> ... <value>VAL</value> ... </setting>
    # Funktioniert auch wenn <value> auf einer eigenen Zeile steht
    local name="$1"
    local newval="$2"
    local file="$3"
    if ! grep -q "setting name=\"${name}\"" "$file" 2>/dev/null; then
        echo "[WARN] Setting '${name}' nicht gefunden in $(basename "$file")"
        return 0
    fi
    sed -i -E "/setting name=\"${name}\"/,/<\/setting>/ s|<value>[^<]*<\/value>|<value>${newval}<\/value>|" "$file"
    echo "[INFO] Patched: ${name} = ${newval}"
}



# Alle .config Dateien im App-Verzeichnis patchen
for CFG in "$APPDIR"/*.config; do
    [ -f "$CFG" ] || continue
    echo "[INFO] Patching: $(basename "$CFG")"

    # ComfoBoxLib Settings (Port, Baudrate, BACnet, MQTT-Broker)
    patch_xml_value "Port"               "$SERIAL_PTY"       "$CFG"
    patch_xml_value "Baudrate"           "$BAUDRATE"         "$CFG"
    patch_xml_value "BacnetMasterId"     "$BACNET_MASTER_ID" "$CFG"
    patch_xml_value "BacnetClientId"     "$BACNET_CLIENT_ID" "$CFG"
    patch_xml_value "MqttBrokerAddress"  "$MQTT_HOST"        "$CFG"

    # ComfoBoxMqtt Settings
    patch_xml_value "BaseTopic"          "$MQTT_BASE_TOPIC"  "$CFG"
    patch_xml_value "WriteTopicsToFile"  "False"             "$CFG"
done

# ── Cleanup Handler ───────────────────────────────────────────────────────────
SER2NET_PID=""
MONO_PID=""

cleanup() {
    echo "[INFO] Shutdown: stoppe Prozesse..."
    [ -n "$MONO_PID" ]    && kill "$MONO_PID"    2>/dev/null || true
    [ -n "$SER2NET_PID" ] && kill "$SER2NET_PID" 2>/dev/null || true
    rm -f /tmp/ser2net.conf
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── ser2net: TCP → virtueller serieller Port ──────────────────────────────────
# ser2net erstellt /dev/ttyV0 als echtes TTY-Device das Mono/dotnet korrekt
# öffnen kann. socat PTY schlug fehl weil Alpine/Mono isatty() auf PTY-Slave
# ablehnt ("Not a tty").
SERIAL_DEV="/dev/ttyV0"

echo "[INFO] Starte ser2net: ${WAVESHARE_HOST}:${WAVESHARE_PORT} → ${SERIAL_DEV}"

# ser2net Konfigurationsdatei erstellen
cat > /tmp/ser2net.conf << EOF
connection: &con1
  accepter: serialdev,${SERIAL_DEV},${BAUDRATE}n81
  connector: tcp,${WAVESHARE_HOST},${WAVESHARE_PORT}
  options:
    kickolduser: true
EOF

# ser2net starten
ser2net -c /tmp/ser2net.conf -n &
SER2NET_PID=$!

# Warten bis /dev/ttyV0 erscheint (max 15 Sekunden)
echo "[INFO] Warte auf ${SERIAL_DEV}..."
for i in $(seq 1 15); do
    if [ -e "$SERIAL_DEV" ]; then
        echo "[INFO] ${SERIAL_DEV} bereit nach ${i}s"
        break
    fi
    sleep 1
    if [ "$i" -eq 15 ]; then
        echo "[ERROR] ${SERIAL_DEV} nicht bereit nach 15s"
        echo "[DEBUG] ser2net PID=${SER2NET_PID} aktiv: $(kill -0 "$SER2NET_PID" 2>/dev/null && echo ja || echo nein)"
        echo "[DEBUG] /dev Inhalt (tty*):"
        ls -la /dev/tty* 2>/dev/null || echo "(keine tty devices)"
        kill "$SER2NET_PID" 2>/dev/null || true
        exit 1
    fi
done

# Config mit /dev/ttyV0 patchen
for CFG in "$APPDIR"/*.config; do
    [ -f "$CFG" ] || continue
    patch_xml_value "Port" "$SERIAL_DEV" "$CFG"
done

# ── Mono: RF77 ComfoBoxMqttConsole starten ────────────────────────────────────
echo "[INFO] Starte mono ${EXE_PATH}"
cd "$APPDIR"
mono "${EXE_PATH}" &
MONO_PID=$!

echo "[INFO] Läuft — ser2net PID=${SER2NET_PID}, mono PID=${MONO_PID}"

# Prozesse überwachen
while true; do
    if ! kill -0 "$SER2NET_PID" 2>/dev/null; then
        echo "[ERROR] ser2net abgestürzt — beende Addon"
        cleanup
    fi
    if ! kill -0 "$MONO_PID" 2>/dev/null; then
        echo "[ERROR] mono abgestürzt — beende Addon"
        cleanup
    fi
    sleep 10
done
