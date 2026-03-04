#!/usr/bin/with-contenv bash
set -euo pipefail

# =========================
# Simple + stable run.sh
# - unzip RF77 bundle
# - start socat TCP->PTY
# - patch ComfoBoxMqttConsole.exe.config (baud + IDs + MQTT + serial)
# - run mono in foreground with restart loop (so add-on stays up)
# =========================

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err() { echo "[ERROR] $*" >&2; }

# ---- Options / env (keep compatible with what you already logged) ----
WAVESHARE="${WAVESHARE:-192.168.0.24:4197}"
SERIAL_LINK="${SERIAL_LINK:-/tmp/comfobox}"
BAUD="${BAUD:-76800}"

MQTT_HOST="${MQTT_HOST:-core-mosquitto}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_BASE_TOPIC="${MQTT_BASE_TOPIC:-ComfoBox}"

BACNET_MASTER_ID="${BACNET_MASTER_ID:-1}"
BACNET_CLIENT_ID="${BACNET_CLIENT_ID:-3}"

# RF77 bundle location and extraction directory
RF77_ZIP="${RF77_ZIP:-/app/rf77.zip}"
RF77_DIR="${RF77_DIR:-/app/rf77}"

# Restart loop delay (seconds)
RESTART_DELAY="${RESTART_DELAY:-5}"

SOCAT_PID=""

cleanup() {
  warn "Stopping..."
  if [ -n "${SOCAT_PID}" ] && kill -0 "${SOCAT_PID}" >/dev/null 2>&1; then
    kill "${SOCAT_PID}" >/dev/null 2>&1 || true
  fi
  exit 0
}

trap cleanup SIGTERM SIGINT

log "run.sh starting"
log "waveshare=${WAVESHARE}"
log "serial=${SERIAL_LINK} baud=${BAUD}"
log "mqtt=${MQTT_HOST}:${MQTT_PORT}"
log "mqtt_base_topic=${MQTT_BASE_TOPIC}"
log "bacnet_master_id=${BACNET_MASTER_ID} bacnet_client_id=${BACNET_CLIENT_ID}"

# ---- Validate RF77 zip ----
if [ ! -f "${RF77_ZIP}" ]; then
  err "RF77 zip not found: ${RF77_ZIP}"
  err "Place the RF77 bundle there or set RF77_ZIP accordingly."
  exit 1
fi

# ---- Fresh extract every start (reproducible) ----
log "Cleaning previous RF77 folder"
rm -rf "${RF77_DIR}"
mkdir -p "${RF77_DIR}"

log "Unzipping RF77 package"
unzip -q "${RF77_ZIP}" -d "${RF77_DIR}"

# ---- Locate EXE + config ----
EXE_PATH="$(find "${RF77_DIR}" -type f -name 'ComfoBoxMqttConsole.exe' | head -n 1 || true)"
if [ -z "${EXE_PATH}" ]; then
  err "ComfoBoxMqttConsole.exe not found under ${RF77_DIR}"
  exit 1
fi
CFG_PATH="${EXE_PATH}.config"

log "RF77 detected at: $(dirname "${EXE_PATH}")"
log "Config file: ${CFG_PATH}"

if [ ! -f "${CFG_PATH}" ]; then
  err "Config file missing: ${CFG_PATH}"
  exit 1
fi

# ---- Start socat (TCP->PTY) ----
log "Starting socat (TCP->PTY)..."
pkill -f "socat.*${SERIAL_LINK}" >/dev/null 2>&1 || true
rm -f "${SERIAL_LINK}"

# waitslave prevents early connect race; raw/echo=0 for serial-like behavior
socat "TCP:${WAVESHARE}" "PTY,link=${SERIAL_LINK},raw,echo=0,waitslave" &
SOCAT_PID="$!"

# Wait until PTY link is ready
for _ in $(seq 1 50); do
  if [ -L "${SERIAL_LINK}" ] || [ -e "${SERIAL_LINK}" ]; then
    break
  fi
  sleep 0.1
done
ls -l "${SERIAL_LINK}" || true

# ---- Patch RF77 .exe.config (XML settings) ----
log "Patching config"

export CFG_PATH SERIAL_LINK BAUD MQTT_HOST MQTT_PORT MQTT_BASE_TOPIC BACNET_MASTER_ID BACNET_CLIENT_ID

python3 - <<'PY'
import os, re, pathlib

cfg = os.environ["CFG_PATH"]
serial_link = os.environ["SERIAL_LINK"]
baud = os.environ["BAUD"]
mqtt_host = os.environ["MQTT_HOST"]
mqtt_port = os.environ["MQTT_PORT"]
mqtt_base = os.environ["MQTT_BASE_TOPIC"]
bacnet_master = os.environ["BACNET_MASTER_ID"]
bacnet_client = os.environ["BACNET_CLIENT_ID"]

p = pathlib.Path(cfg)
text = p.read_text(encoding="utf-8", errors="replace")

def set_setting(name: str, value: str, s: str):
    # <setting name="X" ...><value>...</value></setting>
    pat = re.compile(r'(<setting\s+name="'+re.escape(name)+r'".*?>\s*<value>)(.*?)(</value>)', re.DOTALL)
    if pat.search(s):
        s = pat.sub(r'\1'+str(value)+r'\3', s)
        return s, True
    return s, False

changes = {
    "SerialPort": serial_link,
    "Baudrate": baud,
    "MqttHost": mqtt_host,
    "MqttPort": mqtt_port,
    "MqttBaseTopic": mqtt_base,
    "BacnetMasterId": bacnet_master,
    "BacnetClientId": bacnet_client,
}

done, missing = [], []
for k, v in changes.items():
    text, ok = set_setting(k, v, text)
    (done if ok else missing).append(k)

p.write_text(text, encoding="utf-8")

print("[INFO] Patched settings: " + ", ".join(done))
if missing:
    print("[WARN] Settings not found (not patched): " + ", ".join(missing))
PY

# ---- Run console in FOREGROUND with restart loop ----
log "Starting ComfoBoxMqttConsole (foreground; will restart on exit)"

while true; do
  log "Launching: mono ${EXE_PATH}"
  # Prefix output so it is visible in HA logs; keep it simple and readable
  mono "${EXE_PATH}" 2>&1 | sed 's/^/[RF77] /'
  rc=${PIPESTATUS[0]}

  # rc=0 means the app chose to exit; without loop the add-on would stop
  warn "ComfoBoxMqttConsole exited with rc=${rc}. Restarting in ${RESTART_DELAY}s..."
  sleep "${RESTART_DELAY}"
done
