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
SOCAT_PID=""
MONO_PID=""

cleanup() {
    echo "[INFO] Shutdown: stoppe Prozesse..."
    [ -n "$MONO_PID" ]  && kill "$MONO_PID"  2>/dev/null || true
    [ -n "$SOCAT_PID" ] && kill "$SOCAT_PID" 2>/dev/null || true
    rm -f /tmp/comfobox
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── socat: virtueller serieller Port ─────────────────────────────────────────
# Verwendet waitslave damit socat wartet bis Mono den Slave-PTY öffnet.
# group-late=dialout und mode=660 geben Mono Zugriff auf den PTY.
SERIAL_DEV="/tmp/comfobox"

echo "[INFO] Starte socat PTY-Bridge: ${WAVESHARE_HOST}:${WAVESHARE_PORT} → ${SERIAL_DEV}"

rm -f "$SERIAL_DEV"

socat \
    "pty,link=${SERIAL_DEV},waitslave,group-late=root,mode=666" \
    "TCP:${WAVESHARE_HOST}:${WAVESHARE_PORT},keepalive,nodelay,retry=10,interval=3" \
    &
SOCAT_PID=$!

# Warten bis Symlink erscheint (max 15 Sekunden)
echo "[INFO] Warte auf ${SERIAL_DEV}..."
for i in $(seq 1 15); do
    if [ -e "$SERIAL_DEV" ]; then
        echo "[INFO] ${SERIAL_DEV} bereit nach ${i}s"
        # Echten PTY-Pfad ermitteln und loggen
        REAL_PTY="$(readlink -f "$SERIAL_DEV" 2>/dev/null || echo "$SERIAL_DEV")"
        echo "[INFO] Echter PTY-Pfad: ${REAL_PTY}"
        echo "[DEBUG] PTY permissions: $(ls -la "$REAL_PTY" 2>/dev/null || echo 'unbekannt')"
        break
    fi
    sleep 1
    if [ "$i" -eq 15 ]; then
        echo "[ERROR] ${SERIAL_DEV} nicht bereit nach 15s"
        kill "$SOCAT_PID" 2>/dev/null || true
        exit 1
    fi
done

# PTY-Berechtigungen explizit setzen damit Mono zugreifen kann
REAL_PTY="$(readlink -f "$SERIAL_DEV" 2>/dev/null || echo "$SERIAL_DEV")"
chmod 666 "$REAL_PTY" 2>/dev/null || true

# Config mit dem ECHTEN PTY-Pfad patchen (nicht Symlink!)
# Mono's isatty() schlägt auf Symlinks fehl — braucht echtes /dev/pts/X
for CFG in "$APPDIR"/*.config; do
    [ -f "$CFG" ] || continue
    patch_xml_value "Port" "$REAL_PTY" "$CFG"
done

# ── Mono: RF77 ComfoBoxMqttConsole starten ────────────────────────────────────
echo "[INFO] Starte mono ${EXE_PATH}"
cd "$APPDIR"
mono "${EXE_PATH}" &
MONO_PID=$!

echo "[INFO] Läuft — socat PID=${SOCAT_PID}, mono PID=${MONO_PID}"

# Prozesse überwachen
while true; do
    if ! kill -0 "$SOCAT_PID" 2>/dev/null; then
        echo "[ERROR] socat abgestürzt — beende Addon"
        cleanup
    fi
    if ! kill -0 "$MONO_PID" 2>/dev/null; then
        echo "[ERROR] mono abgestürzt — beende Addon"
        cleanup
    fi
    sleep 10
done
