#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] ComfoBox MQTT Bridge starting..."

# ── Konfiguration aus HA options.json lesen ────────────────────────────────────
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
MQTT_BASE_TOPIC="$(get_opt mqtt_base_topic "ComfoBox")"
BACNET_MASTER_ID="$(get_opt bacnet_master_id "1")"
BACNET_CLIENT_ID="$(get_opt bacnet_client_id "3")"

PTY_LINK="/tmp/comfobox_pty"

echo "[INFO] Waveshare:    ${WAVESHARE_HOST}:${WAVESHARE_PORT}"
echo "[INFO] Baudrate:     ${BAUDRATE}"
echo "[INFO] MQTT:         ${MQTT_HOST}:${MQTT_PORT}"
echo "[INFO] MQTT topic:   ${MQTT_BASE_TOPIC}"
echo "[INFO] BACnet:       master=${BACNET_MASTER_ID} client=${BACNET_CLIENT_ID}"

# ── Validierung ──────────────────────────────────────────────────────────────────
if [ -z "$WAVESHARE_HOST" ] || [ "$WAVESHARE_PORT" = "0" ]; then
    echo "[ERROR] waveshare_host und waveshare_port müssen konfiguriert sein!"
    exit 1
fi

# ── ZIP entpacken ────────────────────────────────────────────────────────────────
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

# ── Cleanup Handler ──────────────────────────────────────────────────────────────
SOCAT_PID=""
MONO_PID=""

cleanup() {
    echo "[INFO] Shutdown: stoppe Prozesse..."
    [ -n "$MONO_PID" ]  && kill "$MONO_PID"  2>/dev/null || true
    [ -n "$SOCAT_PID" ] && kill "$SOCAT_PID" 2>/dev/null || true
    rm -f "$PTY_LINK" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── Schritt 1: socat PTY-Bridge starten ─────────────────────────────────────────
# socat erstellt PTY-Paar und legt Symlink an.
# rawer    → minimale TTY-Verarbeitung, keine Sonderzeichen-Interpretation
# echo=0   → kein lokales Echo
rm -f "$PTY_LINK" 2>/dev/null || true

echo "[INFO] Starte socat PTY-Bridge: ${WAVESHARE_HOST}:${WAVESHARE_PORT} → ${PTY_LINK}"
socat \
    "PTY,link=${PTY_LINK},rawer,echo=0,ispeed=${BAUDRATE},ospeed=${BAUDRATE}" \
    "TCP:${WAVESHARE_HOST}:${WAVESHARE_PORT},keepalive,nodelay,retry=10,interval=3" \
    &
SOCAT_PID=$!

# Warten bis socat den Symlink angelegt hat (max. 10s)
echo "[INFO] Warte auf ${PTY_LINK}..."
for i in $(seq 1 10); do
    if [ -L "$PTY_LINK" ]; then
        echo "[INFO] ${PTY_LINK} bereit nach ${i}s"
        break
    fi
    if ! kill -0 "$SOCAT_PID" 2>/dev/null; then
        echo "[ERROR] socat sofort abgestürzt — Waveshare erreichbar? ${WAVESHARE_HOST}:${WAVESHARE_PORT}"
        exit 1
    fi
    sleep 1
done

if [ ! -L "$PTY_LINK" ]; then
    echo "[ERROR] ${PTY_LINK} nicht bereit nach 10s"
    kill "$SOCAT_PID" 2>/dev/null || true
    exit 1
fi

# Echten /dev/pts/X Pfad auslesen
REAL_PTY="$(readlink -f "$PTY_LINK")"
echo "[INFO] PTY bereit: ${PTY_LINK} → ${REAL_PTY}"

# PTY-Berechtigungen setzen
chmod 666 "$REAL_PTY" 2>/dev/null || true

# ── Schritt 2: RF77 Config mit echtem /dev/pts/X patchen ────────────────────────
# Mono öffnet den Port direkt über den konfigurierten Pfad.
# Wir übergeben den echten /dev/pts/X — das ist ein echter PTY-Device-Node,
# isatty() besteht weil es ein character device mit TTY-Semantik ist.
patch_xml_value() {
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

for CFG in "$APPDIR"/*.config; do
    [ -f "$CFG" ] || continue
    echo "[INFO] Patching: $(basename "$CFG")"
    patch_xml_value "Port"              "$REAL_PTY"         "$CFG"
    patch_xml_value "Baudrate"          "$BAUDRATE"         "$CFG"
    patch_xml_value "BacnetMasterId"    "$BACNET_MASTER_ID" "$CFG"
    patch_xml_value "BacnetClientId"    "$BACNET_CLIENT_ID" "$CFG"
    patch_xml_value "MqttBrokerAddress" "$MQTT_HOST"        "$CFG"
    patch_xml_value "BaseTopic"         "$MQTT_BASE_TOPIC"  "$CFG"
    patch_xml_value "WriteTopicsToFile" "False"             "$CFG"
done

# ── Schritt 3: PTY-Slave auf Baudrate konfigurieren ─────────────────────────────
# Mono ruft intern tcsetattr() auf dem PTY auf um die Baudrate zu setzen.
# PTY-Slaves antworten auf ioctl TCSETS mit ENOTTY wenn keine Baudrate gesetzt ist.
# Mit stty die Baudrate vorab setzen damit Mono keinen Fehler bekommt.
echo "[INFO] Setze PTY Baudrate: ${BAUDRATE}"
stty -F "${REAL_PTY}" "${BAUDRATE}" raw -echo 2>/dev/null || true

# ── Schritt 4: Mono starten ──────────────────────────────────────────────────────
echo "[INFO] Starte mono ${EXE_PATH}"
cd "$APPDIR"
mono "${EXE_PATH}" &
MONO_PID=$!

echo "[INFO] Läuft — socat PID=${SOCAT_PID}, mono PID=${MONO_PID}"

# ── Prozessüberwachung ───────────────────────────────────────────────────────────
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
