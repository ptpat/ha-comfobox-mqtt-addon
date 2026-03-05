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
BAUDRATE="$(get_opt baudrate "38400")"
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
    exit 1
fi

APPDIR="$(dirname "$EXE_PATH")"
echo "[INFO] EXE gefunden: $EXE_PATH"

# ── Cleanup Handler ──────────────────────────────────────────────────────────────
SOCAT_TCP_PID=""
SOCAT_PTY_PID=""
MONO_PID=""

cleanup() {
    echo "[INFO] Shutdown: stoppe Prozesse..."
    [ -n "$MONO_PID" ]      && kill "$MONO_PID"      2>/dev/null || true
    [ -n "$SOCAT_PTY_PID" ] && kill "$SOCAT_PTY_PID" 2>/dev/null || true
    [ -n "$SOCAT_TCP_PID" ] && kill "$SOCAT_TCP_PID" 2>/dev/null || true
    rm -f /tmp/comfobox_pipe_in /tmp/comfobox_pipe_out /tmp/comfobox_pty 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── Schritt 1: Zwei PTYs via socat verbinden ─────────────────────────────────────
# Strategie: socat verbindet zwei PTY-Paare.
# PTY-A (Slave A) → socat ↔ socat → PTY-B (Slave B)
# Mono bekommt PTY-A: isatty() = true, tcsetattr() = ok (PTY unterstützt das)
# socat leitet Daten weiter zu TCP (Waveshare)
#
# Tatsächlich: Ein PTY unterstützt tcsetattr NICHT vollständig → ENOTTY
# Die wirkliche Lösung: socat mit PIPE zwischen PTY und TCP
#
# Korrekte Lösung: Named Pipe (FIFO) — Mono bekommt einen regulären PTY,
# aber wir erstellen den PTY direkt via 'socat PTY PTY' damit beide Seiten
# TTY-Semantik haben.

PTY_MONO="/tmp/comfobox_mono_pty"   # Mono öffnet diesen
PTY_TCP="/tmp/comfobox_tcp_pty"     # socat-TCP-Seite

rm -f "$PTY_MONO" "$PTY_TCP" 2>/dev/null || true

echo "[INFO] Starte socat PTY↔PTY Bridge..."
# socat verbindet zwei PTY-Slaves direkt miteinander
# PTY_MONO → Mono liest/schreibt hier
# PTY_TCP  → wird von zweitem socat zu TCP weitergeleitet
socat \
    "PTY,link=${PTY_MONO},raw,echo=0,mode=666" \
    "PTY,link=${PTY_TCP},raw,echo=0,mode=666" \
    &
SOCAT_PTY_PID=$!

echo "[INFO] Warte auf PTY-Symlinks..."
for i in $(seq 1 10); do
    if [ -L "$PTY_MONO" ] && [ -L "$PTY_TCP" ]; then
        echo "[INFO] PTY-Symlinks bereit nach ${i}s"
        break
    fi
    if ! kill -0 "$SOCAT_PTY_PID" 2>/dev/null; then
        echo "[ERROR] socat PTY↔PTY abgestürzt"
        exit 1
    fi
    sleep 1
done

REAL_PTY_MONO="$(readlink -f "$PTY_MONO")"
REAL_PTY_TCP="$(readlink -f "$PTY_TCP")"
echo "[INFO] PTY Mono: ${PTY_MONO} → ${REAL_PTY_MONO}"
echo "[INFO] PTY TCP:  ${PTY_TCP}  → ${REAL_PTY_TCP}"

# ── Schritt 2: TCP-Seite mit Waveshare verbinden ─────────────────────────────────
echo "[INFO] Starte socat TCP-Bridge: ${REAL_PTY_TCP} → ${WAVESHARE_HOST}:${WAVESHARE_PORT}"
socat \
    "file:${REAL_PTY_TCP},raw,echo=0" \
    "TCP:${WAVESHARE_HOST}:${WAVESHARE_PORT},keepalive,nodelay,retry=10,interval=3" \
    &
SOCAT_TCP_PID=$!

sleep 1
if ! kill -0 "$SOCAT_TCP_PID" 2>/dev/null; then
    echo "[ERROR] socat TCP abgestürzt — Waveshare erreichbar? ${WAVESHARE_HOST}:${WAVESHARE_PORT}"
    exit 1
fi
echo "[INFO] TCP-Bridge läuft (PID=${SOCAT_TCP_PID})"

# ── Schritt 3: RF77 Config patchen ───────────────────────────────────────────────
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

echo "[INFO] Patching: ComfoBoxMqttConsole.exe.config"
for CFG in "$APPDIR"/*.config; do
    [ -f "$CFG" ] || continue
    patch_xml_value "Port"              "$REAL_PTY_MONO"    "$CFG"
    patch_xml_value "Baudrate"          "$BAUDRATE"         "$CFG"
    patch_xml_value "BacnetMasterId"    "$BACNET_MASTER_ID" "$CFG"
    patch_xml_value "BacnetClientId"    "$BACNET_CLIENT_ID" "$CFG"
    patch_xml_value "MqttBrokerAddress" "$MQTT_HOST"        "$CFG"
    patch_xml_value "MqttBrokerPort"    "$MQTT_PORT"        "$CFG"
    patch_xml_value "BaseTopic"         "$MQTT_BASE_TOPIC"  "$CFG"
    patch_xml_value "WriteTopicsToFile" "False"             "$CFG"
done

# ── Schritt 4: Mono starten ──────────────────────────────────────────────────────
echo "[INFO] Starte mono ${EXE_PATH}"
cd "$APPDIR"
mono "${EXE_PATH}" &
MONO_PID=$!

echo "[INFO] Läuft — socat-pty PID=${SOCAT_PTY_PID}, socat-tcp PID=${SOCAT_TCP_PID}, mono PID=${MONO_PID}"

# ── Prozessüberwachung ───────────────────────────────────────────────────────────
while true; do
    if ! kill -0 "$SOCAT_PTY_PID" 2>/dev/null; then
        echo "[ERROR] socat PTY abgestürzt — beende Addon"
        cleanup
    fi
    if ! kill -0 "$SOCAT_TCP_PID" 2>/dev/null; then
        echo "[ERROR] socat TCP abgestürzt — beende Addon"
        cleanup
    fi
    if ! kill -0 "$MONO_PID" 2>/dev/null; then
        echo "[ERROR] mono abgestürzt — beende Addon"
        cleanup
    fi
    sleep 10
done
