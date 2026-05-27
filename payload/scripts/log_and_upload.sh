#!/bin/bash
# =============================================================================
# snareSAR GNSS Base Station — 10-minute data logging cycle (v8)
#
# v8 (2026-04-17): Station-agnostic. STATION_ID is now read from
# station.conf (first non-blank, non-comment line after the coords).
# Same file runs on MY_STATION and MY_STATION with identical md5. All station-
# specific data lives in station.conf.
#
# v7 eliminated pre-capture receiver detection (which caused data loss
# when the FTDI buffer held stale bytes). v7 captures first, validates
# after, runs ensure_receiver.py only as fallback.
#
# Pipeline:
#   1. Acquire lock (refuse if previous cycle still running)
#   2. Kill any stale str2str processes on ttyUSB0
#   3. Re-activate GCS service account if needed
#   4. Read last-known-good baud from baud.conf (default 115200)
#   5. Retry any leftover RINEX files from previous failed uploads
#   6. str2str serial://ttyUSB0 → ${TIMESTAMP}.ubx  (LOG_DURATION seconds)
#   7. Validate capture contains >= 2 UBX sync markers
#   8. If invalid: flush serial, run ensure_receiver.py, retry capture
#   9. convbin → RINEX 3.03 .obs/.nav
#  10. Inject APPROX POSITION XYZ from station.conf
#  11. Upload each RINEX file, verify in GCS, delete local copy on success
#  12. Rotate automation.log if > 10 MiB
#
# Cron: */10 * * * * /home/xeroth/base_station/scripts/log_and_upload.sh
# =============================================================================

set -u

GCP_BUCKET="gs://xeroth-base-stations-data"
DEFAULT_BAUD="115200"
LOG_DIR="/home/xeroth/base_station/logs"
SERIAL_PORT="/dev/ttyUSB0"
LOG_DURATION=480
STATION_CONF="/home/xeroth/base_station/scripts/station.conf"
GCS_KEY="/home/xeroth/base_station/gnss-uploader-key.json"
ENSURE_RECEIVER="/home/xeroth/base_station/scripts/ensure_receiver.py"
LOCK_FILE="/tmp/gnss-cycle.lock"
BAUD_FILE="/home/xeroth/base_station/scripts/baud.conf"
HEARTBEAT_FILE="/home/xeroth/base_station/state/cycle.heartbeat"
MAX_LOG_BYTES=10485760

STR2STR_EXEC="/usr/local/bin/str2str"
CONVBIN_EXEC="/usr/local/bin/convbin"
GCLOUD_EXEC="/usr/bin/gcloud"
DATE_EXEC="/usr/bin/date"
SLEEP_EXEC="/usr/bin/sleep"

LOG_FILE="${LOG_DIR}/automation.log"
STR2STR_PORT="ttyUSB0"

# Ensure LOG_DIR and state dir exist before the first log() call.
# On a pristine install these may not exist yet; log() appends silently
# fail without this, swallowing the earliest cycle messages.
mkdir -p "${LOG_DIR}" 2>/dev/null || true
mkdir -p "$(dirname "${HEARTBEAT_FILE}")" 2>/dev/null || true

# Resolve STATION_ID from station.conf. Format:
#   # comments …
#   STATION_ID=MY_STATION
#   # more comments …
#   <x> <y> <z>
STATION_ID=""
if [ -f "${STATION_CONF}" ]; then
    STATION_ID=$(grep -E '^[[:space:]]*STATION_ID[[:space:]]*=' "${STATION_CONF}" \
                 | head -n 1 | sed 's/^[[:space:]]*STATION_ID[[:space:]]*=[[:space:]]*//' | tr -d '"')
fi
if [ -z "${STATION_ID}" ]; then
    STATION_ID=$(hostname | tr '[:lower:]' '[:upper:]')
fi

log() { echo "$(${DATE_EXEC} -u +"%Y-%m-%d %H:%M:%S UTC") [${STATION_ID}] $1" >> "${LOG_FILE}"; }

heartbeat() {
    mkdir -p "$(dirname "${HEARTBEAT_FILE}")" 2>/dev/null || true
    printf '%s %s\n' "$(${DATE_EXEC} -u +%s)" "$1" > "${HEARTBEAT_FILE}" 2>/dev/null || true
}

# --- Log rotation ---
rotate_log() {
    if [ -f "${LOG_FILE}" ]; then
        local size
        size=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo "0")
        if [ "${size}" -gt "${MAX_LOG_BYTES}" ]; then
            mv "${LOG_FILE}" "${LOG_FILE}.1"
            log "Log rotated (previous was ${size} bytes)"
        fi
    fi
}

# --- Serial port flush ---
# Drains the FTDI USB-serial chip's internal buffers at both common baud rates.
flush_serial() {
    python3 -c "
import serial, time
for baud in [115200, 38400]:
    try:
        s = serial.Serial('${SERIAL_PORT}', baud, timeout=0.5)
        s.reset_input_buffer(); s.reset_output_buffer()
        end = time.time() + 2
        while time.time() < end:
            s.read(4096)
        s.reset_input_buffer(); s.close()
    except Exception:
        pass
" 2>/dev/null
}

# --- UBX data validation ---
# Returns 0 if the file contains valid UBX data (>= 2 sync markers).
validate_ubx() {
    local file="$1"
    [ -s "${file}" ] || return 1
    local count
    count=$(python3 -c "
data = open('${file}', 'rb').read(20000)
print(data.count(b'\xb5\x62'))
" 2>/dev/null)
    [ -n "${count}" ] && [ "${count}" -ge 2 ] && return 0
    return 1
}

# Upload a single file to GCS prefix, verify it landed, then delete local copy.
upload_and_verify() {
    local local_file="$1"
    local gcs_prefix="$2"
    local basename
    basename=$(basename "${local_file}")
    local gcs_path="${gcs_prefix}/${basename}"

    local upload_err
    upload_err=$(${GCLOUD_EXEC} storage cp "${local_file}" "${gcs_path}" 2>&1)
    if [ $? -ne 0 ]; then
        log "ERROR: upload failed for ${basename}: ${upload_err}"
        return 1
    fi

    local verify_err
    verify_err=$(${GCLOUD_EXEC} storage ls "${gcs_path}" 2>&1)
    if [ $? -ne 0 ]; then
        log "ERROR: verification failed for ${gcs_path} — local file retained: ${verify_err}"
        return 1
    fi

    rm -f "${local_file}"
    return 0
}

# Extract year and DOY from a RINEX filename like 202604071230.obs
filename_to_gcs_prefix() {
    local basename
    basename=$(basename "$1")
    local ts="${basename%%.*}"
    if [ ${#ts} -ge 8 ]; then
        local ymd="${ts:0:8}"
        local year="${ymd:0:4}"
        local doy
        doy=$(${DATE_EXEC} -u -d "${ymd:0:4}-${ymd:4:2}-${ymd:6:2}" +"%j" 2>/dev/null)
        if [ -n "${doy}" ] && [ -n "${year}" ]; then
            echo "${GCP_BUCKET}/${STATION_ID}/${year}/${doy}"
            return 0
        fi
    fi
    echo "${GCP_BUCKET}/${STATION_ID}/$(${DATE_EXEC} -u +%Y)/$(${DATE_EXEC} -u +%j)"
    return 1
}

upload_all_rinex() {
    local target_prefix="$1"
    local any_uploaded=0
    local any_failed=0

    for f in "${LOG_DIR}"/*.obs "${LOG_DIR}"/*.rnx "${LOG_DIR}"/*.nav; do
        [ -f "${f}" ] || continue
        local prefix="${target_prefix}"
        if [ -z "${prefix}" ]; then
            prefix=$(filename_to_gcs_prefix "${f}")
        fi
        if upload_and_verify "${f}" "${prefix}"; then
            log "Uploaded $(basename "${f}") to ${prefix}/"
            any_uploaded=1
        else
            any_failed=1
        fi
    done

    [ ${any_failed} -eq 1 ] && return 1
    [ ${any_uploaded} -eq 1 ] && return 0
    return 2
}

# Read APPROX POSITION XYZ triple from station.conf: first non-blank,
# non-comment line that isn't a KEY=VALUE assignment.
read_ppp_xyz() {
    [ -f "${STATION_CONF}" ] || return 1
    local line
    line=$(grep -vE '^[[:space:]]*(#|$|[A-Za-z_][A-Za-z0-9_]*=)' "${STATION_CONF}" | head -n 1)
    [ -n "${line}" ] || return 1
    echo "${line}"
    return 0
}

# --- Receiver recovery (fallback only) ---
recover_receiver() {
    log "Running receiver recovery (ensure_receiver.py fallback)"
    local attempt
    for attempt in $(seq 1 3); do
        flush_serial
        ${SLEEP_EXEC} 2
        local ensure_out
        ensure_out=$(python3 "${ENSURE_RECEIVER}" 2>&1)
        local rc=$?
        local recovered_baud
        recovered_baud=$(echo "${ensure_out}" | tail -1)
        if [ ${rc} -eq 0 ] && [ -n "${recovered_baud}" ] && [ "${recovered_baud}" != "FAILED" ]; then
            BAUD_RATE="${recovered_baud}"
            echo "${BAUD_RATE}" > "${BAUD_FILE}"
            log "Receiver recovered at ${BAUD_RATE} baud (fallback attempt ${attempt})"

            local ts2
            ts2=$(${DATE_EXEC} -u +"%Y%m%d%H%M")
            UBX_FILE="${LOG_DIR}/${ts2}.ubx"
            TIMESTAMP="${ts2}"

            ${STR2STR_EXEC} -in serial://${STR2STR_PORT}:${BAUD_RATE}:8:n:1:off -out "${UBX_FILE}" > /dev/null 2>&1 &
            STR2STR_PID=$!
            ${SLEEP_EXEC} 2
            if ! kill -0 ${STR2STR_PID} 2>/dev/null; then
                log "ERROR: fallback str2str failed to start"
                rm -f "${UBX_FILE}"
                continue
            fi
            ${SLEEP_EXEC} 240
            kill ${STR2STR_PID} 2>/dev/null; wait ${STR2STR_PID} 2>/dev/null

            if validate_ubx "${UBX_FILE}"; then
                log "Fallback captured $(stat -c%s "${UBX_FILE}" 2>/dev/null) bytes"
                return 0
            fi
            log "WARN: fallback capture invalid (attempt ${attempt})"
            rm -f "${UBX_FILE}"
        else
            log "WARN: ensure_receiver.py failed (attempt ${attempt})"
        fi
        [ ${attempt} -lt 3 ] && ${SLEEP_EXEC} 5
    done
    return 1
}

# === MAIN ===

rotate_log
heartbeat "starting"

# --- Lock file ---
if [ -f "${LOCK_FILE}" ]; then
    LOCK_PID=$(cat "${LOCK_FILE}" 2>/dev/null)
    if [ -n "${LOCK_PID}" ] && kill -0 "${LOCK_PID}" 2>/dev/null; then
        log "SKIP: previous cycle still running (PID ${LOCK_PID})"
        exit 0
    else
        rm -f "${LOCK_FILE}"
    fi
fi
echo $$ > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

# --- Kill stale str2str ---
STALE=$(pgrep -f "str2str.*serial://ttyUSB" 2>/dev/null || true)
if [ -n "${STALE}" ]; then
    log "WARN: killing stale str2str (pids: ${STALE})"
    echo "${STALE}" | xargs kill 2>/dev/null
    ${SLEEP_EXEC} 1
    echo "${STALE}" | xargs kill -9 2>/dev/null
fi

# --- Pre-flight ---
[ -c "${SERIAL_PORT}" ] || { log "ERROR: ${SERIAL_PORT} not found"; exit 1; }
[ -x "${STR2STR_EXEC}" ] || { log "ERROR: str2str not found"; exit 1; }
[ -x "${CONVBIN_EXEC}" ] || { log "ERROR: convbin not found"; exit 1; }

# --- Ensure GCS auth ---
if [ -f "${GCS_KEY}" ]; then
    ACTIVE=$(${GCLOUD_EXEC} auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
    if [ -z "${ACTIVE}" ]; then
        log "Re-activating GCS service account"
        ${GCLOUD_EXEC} auth activate-service-account --key-file="${GCS_KEY}" 2>/dev/null
    fi
fi

# --- Determine baud rate ---
BAUD_RATE=""
if [ -f "${BAUD_FILE}" ]; then
    BAUD_RATE=$(cat "${BAUD_FILE}" 2>/dev/null)
fi
if [ -z "${BAUD_RATE}" ] || ! [[ "${BAUD_RATE}" =~ ^[0-9]+$ ]]; then
    BAUD_RATE="${DEFAULT_BAUD}"
fi

# --- Retry leftover uploads ---
# Any .obs/.rnx/.nav sitting in LOG_DIR is the result of a previous cycle
# that captured and converted but failed to upload. Each file is uploaded
# under the GCS prefix DERIVED FROM ITS OWN FILENAME timestamp — not
# today's prefix — so yesterday's leftovers go to yesterday's path.
LEFTOVER=$(find "${LOG_DIR}" -maxdepth 1 \( -name "*.obs" -o -name "*.rnx" -o -name "*.nav" \) 2>/dev/null)
if [ -n "${LEFTOVER}" ]; then
    heartbeat "retrying leftover uploads"
    log "Retrying leftover uploads"
    upload_all_rinex ""
fi

# --- Capture ---
TIMESTAMP=$(${DATE_EXEC} -u +"%Y%m%d%H%M")
UBX_FILE="${LOG_DIR}/${TIMESTAMP}.ubx"

log "Starting cycle ${TIMESTAMP} at ${BAUD_RATE} baud"
heartbeat "capturing ${TIMESTAMP}"

${STR2STR_EXEC} -in serial://${STR2STR_PORT}:${BAUD_RATE}:8:n:1:off -out "${UBX_FILE}" > /dev/null 2>&1 &
STR2STR_PID=$!
${SLEEP_EXEC} 2
if ! kill -0 ${STR2STR_PID} 2>/dev/null; then
    log "ERROR: str2str failed to start"
    rm -f "${UBX_FILE}"
    exit 1
fi
${SLEEP_EXEC} ${LOG_DURATION}
kill ${STR2STR_PID} 2>/dev/null; wait ${STR2STR_PID} 2>/dev/null

# --- Validate capture ---
if ! validate_ubx "${UBX_FILE}"; then
    log "WARN: capture invalid (no UBX data) — receiver may need reconfiguration"
    rm -f "${UBX_FILE}"
    if [ -f "${ENSURE_RECEIVER}" ]; then
        if recover_receiver; then
            log "Recovery succeeded, continuing with fallback capture"
        else
            log "ERROR: receiver recovery failed after all attempts"
            exit 1
        fi
    else
        log "ERROR: no valid UBX data and ensure_receiver.py not found"
        exit 1
    fi
else
    echo "${BAUD_RATE}" > "${BAUD_FILE}"
fi

UBX_SIZE=$(stat -c%s "${UBX_FILE}" 2>/dev/null || echo "0")
log "Captured ${UBX_SIZE} bytes"
heartbeat "converting ${TIMESTAMP}"

# --- Convert ---
# -f 2 = L1+L2 code+phase on GPS/GLONASS, E1+E5b on Galileo, B1I+B2I on BeiDou.
# The ZED-F9P-04B is L1+L2 dual-frequency hardware; -f 1 collapses its
# dual-freq UBX observables to L1-only RINEX and defeats dual-freq PPK.
${CONVBIN_EXEC} -v 3.03 -r ubx -d "${LOG_DIR}" -f 2 "${UBX_FILE}"

# convbin names its output after the UBX basename: ${TIMESTAMP}.obs (or
# .rnx in some builds) and ${TIMESTAMP}.nav. Use deterministic cycle-
# scoped paths rather than find-newest wildcards, which could pick up a
# stale file from a prior failed cycle if clock weirdness ever made its
# mtime appear "newer".
RINEX_OBS="${LOG_DIR}/${TIMESTAMP}.obs"
[ -f "${RINEX_OBS}" ] || RINEX_OBS="${LOG_DIR}/${TIMESTAMP}.rnx"
[ -f "${RINEX_OBS}" ] || RINEX_OBS=""

if [ -z "${RINEX_OBS}" ]; then
    log "ERROR: RINEX conversion failed (UBX had data but convbin produced no output for ${TIMESTAMP})"
    rm -f "${UBX_FILE}"
    if [ -f "${ENSURE_RECEIVER}" ]; then
        if recover_receiver; then
            ${CONVBIN_EXEC} -v 3.03 -r ubx -d "${LOG_DIR}" -f 2 "${UBX_FILE}"
            RINEX_OBS="${LOG_DIR}/${TIMESTAMP}.obs"
            [ -f "${RINEX_OBS}" ] || RINEX_OBS="${LOG_DIR}/${TIMESTAMP}.rnx"
            [ -f "${RINEX_OBS}" ] || RINEX_OBS=""
        fi
    fi
    if [ -z "${RINEX_OBS}" ]; then
        log "ERROR: RINEX conversion failed after recovery"
        rm -f "${UBX_FILE}"
        exit 1
    fi
fi
log "Converted: ${RINEX_OBS}"

# --- PPP coordinates ---
PPP_LINE=$(read_ppp_xyz)
if [ -n "${PPP_LINE}" ]; then
    read -r PPP_X PPP_Y PPP_Z <<<"${PPP_LINE}"
    if [ -n "${PPP_X:-}" ] && [ -n "${PPP_Y:-}" ] && [ -n "${PPP_Z:-}" ]; then
        if [ "${PPP_X}" != "0.0000" ] || [ "${PPP_Y}" != "0.0000" ] || [ "${PPP_Z}" != "0.0000" ]; then
            sed -i "s/.*APPROX POSITION XYZ/$(printf "%14.4f%14.4f%14.4f" $PPP_X $PPP_Y $PPP_Z)                  APPROX POSITION XYZ/" "${RINEX_OBS}"
            log "Injected PPP coordinates"
        fi
    fi
fi

# --- Upload ---
# Always derive the GCS prefix per-file from the filename timestamp
# (via filename_to_gcs_prefix). Passing a hardcoded today-prefix here
# is unsafe: if the leftover-retry at the start of this run failed,
# yesterday's .obs/.nav would still be in LOG_DIR and would then be
# uploaded to today's YYYY/DOY/ path — misfiled by date.
heartbeat "uploading ${TIMESTAMP}"
if upload_all_rinex ""; then
    log "Upload cycle complete"
else
    log "ERROR: Some uploads failed, retained for retry"
fi

# --- Cleanup ---
rm -f "${UBX_FILE}"
find "${LOG_DIR}" -maxdepth 1 -name "*.sbs" -delete 2>/dev/null

heartbeat "idle"
log "Cycle complete"
echo "---" >> "${LOG_FILE}"
