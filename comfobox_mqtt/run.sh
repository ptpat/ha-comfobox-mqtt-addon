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

# ── RF77 Config-Dateien patchen ──────────────────────────────────────────────────
# HINWEIS: Der Port-Wert wird von Mono intern über das PTY gesetzt wenn
# socat Mono via EXEC startet — der Port-Wert in der config ist dann
# der tatsächliche Symlink/PTY den socat anlegt. Wir patchen trotzdem
# alle anderen Werte korrekt.
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
    # Port wird von socat's EXEC+PTY gesetzt — stdout/stdin von Mono ist das PTY
    # Trotzdem einen plausiblen Wert setzen falls Mono ihn direkt liest
    patch_xml_value "Port"              "/dev/tty"          "$CFG"
    patch_xml_value "Baudrate"          "$BAUDRATE"         "$CFG"
    patch_xml_value "BacnetMasterId"    "$BACNET_MASTER_ID" "$CFG"
    patch_xml_value "BacnetClientId"    "$BACNET_CLIENT_ID" "$CFG"
    patch_xml_value "MqttBrokerAddress" "$MQTT_HOST"        "$CFG"
    patch_xml_value "BaseTopic"         "$MQTT_BASE_TOPIC"  "$CFG"
    patch_xml_value "WriteTopicsToFile" "False"             "$CFG"
done

# ── Cleanup Handler ──────────────────────────────────────────────────────────────
SOCAT_PID=""

cleanup() {
    echo "[INFO] Shutdown: stoppe Prozesse..."
    [ -n "$SOCAT_PID" ] && kill "$SOCAT_PID" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── socat: TCP Waveshare ↔ EXEC(mono) mit echtem PTY ────────────────────────────
#
# Ansatz: socat forkt Mono direkt als Kind-Prozess und verbindet dessen
# stdin/stdout über ein echtes PTY mit dem TCP-Stream zum Waveshare.
#
#   pty      → socat erstellt ein PTY-Paar für den EXEC-Prozess
#   setsid   → Mono wird in einer neuen Session gestartet
#   ctty     → das PTY wird als Kontrollterminal gesetzt
#
# Damit besteht isatty() in Mono garantiert — Mono "denkt" es läuft
# an einem echten seriellen Terminal.
#
# Mono liest/schreibt auf stdin/stdout → socat leitet alles transparent
# zum Waveshare TCP-Server weiter.

cd "$APPDIR"

echo "[INFO] Starte socat EXEC(mono) ↔ TCP:${WAVESHARE_HOST}:${WAVESHARE_PORT}"
socat \
    "TCP:${WAVESHARE_HOST}:${WAVESHARE_PORT},keepalive,nodelay,retry=10,interval=3" \
    "EXEC:mono ${EXE_PATH},pty,setsid,ctty" \
    &
SOCAT_PID=$!

echo "[INFO] socat gestartet (PID=${SOCAT_PID})"

# ── Prozessüberwachung ───────────────────────────────────────────────────────────
while true; do
    if ! kill -0 "$SOCAT_PID" 2>/dev/null; then
        echo "[ERROR] socat/mono abgestürzt — beende Addon"
        cleanup
    fi
    sleep 10
done
