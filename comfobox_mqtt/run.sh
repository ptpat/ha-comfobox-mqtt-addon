#!/usr/bin/with-contenv bash
set -euo pipefail

echo "[INFO] run.sh v6 (options.json + socat + safe .config patch) starting"

APP_DIR="/app"
ZIP="${APP_DIR}/ComfoBox2Mqtt_0.4.0.zip"
UNZIP_DIR="${APP_DIR}/ComfoBox2Mqtt"
EXE="${UNZIP_DIR}/ComfoBoxMqttConsole.exe"
CFG="${UNZIP_DIR}/ComfoBoxMqttConsole.exe.config"

OPTIONS_JSON="/data/options.json"

# ---------- helpers ----------
read_json() {
  # usage: read_json ".key" "default"
  local jq_expr="${1}"
  local def="${2:-}"
  if [[ -f "${OPTIONS_JSON}" ]]; then
    local val
    val="$(jq -r "${jq_expr} // empty" "${OPTIONS_JSON}" 2>/dev/null || true)"
    if [[ -n "${val}" && "${val}" != "null" ]]; then
      echo "${val}"
      return 0
    fi
  fi
  echo "${def}"
}

mask() {
  local s="${1:-}"
  if [[ -z "${s}" ]]; then echo ""; else echo "***"; fi
}

ensure_console_present() {
  if [[ ! -d "${UNZIP_DIR}" || ! -f "${EXE}" ]]; then
    echo "[INFO] Extracting RF77 zip..."
    if [[ ! -f "${ZIP}" ]]; then
      echo "[ERROR] RF77 zip not found: ${ZIP}"
      echo "[ERROR] Listing ${APP_DIR}:"
      ls -la "${APP_DIR}" || true
      exit 1
    fi
    rm -rf "${UNZIP_DIR}"
    mkdir -p "${UNZIP_DIR}"
    # unzip may create nested folder - we handle it below
    unzip -o "${ZIP}" -d "${UNZIP_DIR}" >/dev/null

    # If zip contains files in a subfolder, flatten (common: ComfoBox2Mqtt/ComfoBoxMqttConsole.exe)
    if [[ ! -f "${EXE}" ]]; then
      # search for the exe
      local found
      found="$(find "${UNZIP_DIR}" -maxdepth 3 -type f -name "ComfoBoxMqttConsole.exe" 2>/dev/null | head -n1 || true)"
      if [[ -n "${found}" ]]; then
        local found_dir
        found_dir="$(dirname "${found}")"
        echo "[INFO] Found console in nested dir: ${found_dir}"
        # move contents up to UNZIP_DIR
        shopt -s dotglob
        mv "${found_dir}/"* "${UNZIP_DIR}/" || true
        shopt -u dotglob
      fi
    fi

    if [[ ! -f "${EXE}" ]]; then
      echo "[ERROR] ComfoBoxMqttConsole.exe not found after unzip."
      echo "[ERROR] Listing ${UNZIP_DIR}:"
      find "${UNZIP_DIR}" -maxdepth 3 -type f -print || true
      exit 1
    fi
  fi
}

xml_escape() {
  # minimal XML attribute escaping
  local s="${1}"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  echo "${s}"
}

patch_or_insert_appsetting() {
  # Patch inside <appSettings> ... </appSettings> only, preserving XML order.
  # usage: patch_or_insert_appsetting KEY VALUE
  local key="${1}"
  local value="${2}"
  local esc
  esc="$(xml_escape "${value}")"

  # If <appSettings> block doesn't exist, create it AFTER </configSections> if present, else after <configuration>
  if ! grep -q "<appSettings>" "${CFG}"; then
    echo "[WARN] No <appSettings> found; creating <appSettings> block."
    if grep -q "</configSections>" "${CFG}"; then
      awk '
        {print}
        /<\/configSections>/ && !done {
          print "  <appSettings>"
          print "  </appSettings>"
          done=1
        }
      ' "${CFG}" > "${CFG}.tmp" && mv "${CFG}.tmp" "${CFG}"
    else
      awk '
        {print}
        /<configuration>/ && !done {
          print "  <appSettings>"
          print "  </appSettings>"
          done=1
        }
      ' "${CFG}" > "${CFG}.tmp" && mv "${CFG}.tmp" "${CFG}"
    fi
  fi

  # Replace existing key or insert before </appSettings>
  if grep -q "<add key=\"${key}\"" "${CFG}"; then
    # replace value attribute for that key line
    sed -i -E "s#(<add key=\"${key}\" value=\")([^\"]*)(\"[[:space:]]*/>)#\1${esc}\3#g" "${CFG}"
  else
    # insert new <add .../> before closing tag
    awk -v k="${key}" -v v="${esc}" '
      /<\/appSettings>/ && !done {
        print "    <add key=\"" k "\" value=\"" v "\" />"
        done=1
      }
      {print}
    ' "${CFG}" > "${CFG}.tmp" && mv "${CFG}.tmp" "${CFG}"
  fi
}

# ---------- read addon options ----------
use_socat="$(read_json '.use_socat' 'true')"
waveshare_host="$(read_json '.waveshare_host' '')"
waveshare_port="$(read_json '.waveshare_port' '0')"
serial_port="$(read_json '.serial_port' '/tmp/comfobox')"
baudrate="$(read_json '.baudrate' '38400')"

mqtt_host="$(read_json '.mqtt_host' 'core-mosquitto')"
mqtt_port="$(read_json '.mqtt_port' '1883')"
mqtt_user="$(read_json '.mqtt_user' '')"
mqtt_pass="$(read_json '.mqtt_pass' '')"

echo "[INFO] waveshare=${waveshare_host}:${waveshare_port}"
echo "[INFO] serial=${serial_port} baud=${baudrate}"
echo "[INFO] mqtt=${mqtt_host}:${mqtt_port} user_set=$([[ -n "${mqtt_user}" ]] && echo yes || echo no)"

# ---------- ensure RF77 binaries ----------
ensure_console_present

# ---------- socat ----------
SOCAT_PID=""
if [[ "${use_socat}" == "true" || "${use_socat}" == "1" ]]; then
  if [[ -z "${waveshare_host}" || "${waveshare_port}" == "0" ]]; then
    echo "[ERROR] use_socat=true but waveshare_host/port not set."
    exit 1
  fi

  echo "[INFO] Starting socat..."
  # Create PTY at serial_port (symlink) for RF77 to open
  # PTY,link creates a symlink at serial_port pointing to /dev/pts/X
  socat -d -d \
    "PTY,link=${serial_port},raw,echo=0" \
    "TCP:${waveshare_host}:${waveshare_port},nodelay" &
  SOCAT_PID="$!"
  sleep 1
fi

# ---------- patch RF77 config ----------
if [[ ! -f "${CFG}" ]]; then
  echo "[ERROR] RF77 config not found: ${CFG}"
  echo "[ERROR] Listing ${UNZIP_DIR}:"
  ls -la "${UNZIP_DIR}" || true
  [[ -n "${SOCAT_PID}" ]] && kill "${SOCAT_PID}" || true
  exit 1
fi

echo "[INFO] Patching RF77 config: ${CFG}"

# Keep configSections first. Only touch/add within appSettings.
patch_or_insert_appsetting "SerialPort" "${serial_port}"
patch_or_insert_appsetting "Baudrate" "${baudrate}"
patch_or_insert_appsetting "MqttHost" "${mqtt_host}"
patch_or_insert_appsetting "MqttPort" "${mqtt_port}"

# Only write user/pass if provided; else delete existing (important!)
if [[ -n "${mqtt_user}" ]]; then
  patch_or_insert_appsetting "MqttUser" "${mqtt_user}"
else
  # remove any existing MqttUser line
  sed -i -E '/<add key="MqttUser" /d' "${CFG}"
fi

if [[ -n "${mqtt_pass}" ]]; then
  patch_or_insert_appsetting "MqttPassword" "${mqtt_pass}"
else
  sed -i -E '/<add key="MqttPassword" /d' "${CFG}"
fi

# ---------- debug dump ----------
echo "-----------------------------------------"
echo "[DEBUG] CFG markers:"
nl -ba "${CFG}" | awk '/<configuration>|<configSections>|<\/configSections>|<appSettings>|<\/appSettings>|<applicationSettings>|<\/applicationSettings>/{print}'
echo "-----------------------------------------"
echo "[DEBUG] appSettings (password redacted):"
nl -ba "${CFG}" | sed -E 's/(key="MqttPassword" value=")[^"]+/\1***/' | awk '/<appSettings>/{f=1} f{print} /<\/appSettings>/{f=0}'
echo "-----------------------------------------"
echo "[DEBUG] applicationSettings (if any):"
nl -ba "${CFG}" | awk '/<applicationSettings>/{f=1} f{print} /<\/applicationSettings>/{f=0}'
echo "-----------------------------------------"

# ---------- run ----------
cd "${UNZIP_DIR}"
echo "[INFO] Starting ComfoBoxMqttConsole..."
set +e
mono "${EXE}"
rc=$?
set -e

echo "[ERROR] ComfoBoxMqttConsole exited with code ${rc}"

if [[ -n "${SOCAT_PID}" ]]; then
  echo "[INFO] Stopping socat (pid=${SOCAT_PID})"
  kill "${SOCAT_PID}" >/dev/null 2>&1 || true
fi

exit "${rc}"
