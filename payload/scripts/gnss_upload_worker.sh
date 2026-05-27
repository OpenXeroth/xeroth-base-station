#!/bin/bash
# =============================================================================
# snareSAR GNSS base station — upload worker (continuous-capture pipeline)
#
# Runs from cron every minute. Reads closed UBX rotation files written by
# gnss-capture.service (which writes /home/xeroth/base_station/logs/raw/
# %Y%m%d%h%M.ubx, rotating on every 10-minute UTC boundary). For each
# closed file (i.e. every file whose slot is not the currently-writing
# slot), it runs convbin → RINEX 3.03, injects APPROX POSITION XYZ from
# station.conf, uploads .obs and .nav to GCS, verifies each upload, and
# deletes the local copies on success. Files that fail to upload stay on
# disk and are retried the next time this worker runs.
#
# Offline-resilience rules enforced here:
#   1. convbin is only run if the matching RINEX does not already exist.
#      Under a long outage the same raw UBX would otherwise be re-converted
#      every minute, wasting CPU and SD wear.
#   2. Every call to gcloud is wrapped in a hard timeout (GCLOUD_TIMEOUT_S).
#      Without this a flaky network can leave the worker blocked
#      indefinitely on a single TCP connection, starving all subsequent
#      slots.
#
# The capture itself is NOT done here — gnss-capture.service handles it
# continuously with zero gap between 10-minute files. This worker never
# touches the serial port.
#
# Cron: * * * * * /home/xeroth/base_station/scripts/gnss_upload_worker.sh
# =============================================================================

set -u

GCP_BUCKET="gs://xeroth-base-stations-data"
LOG_DIR="/home/xeroth/base_station/logs"
RAW_DIR="${LOG_DIR}/raw"
STATION_CONF="/home/xeroth/base_station/scripts/station.conf"
GCS_KEY="/home/xeroth/base_station/gnss-uploader-key.json"
LOCK_FILE="/tmp/gnss-upload-worker.lock"
HEARTBEAT_FILE="/home/xeroth/base_station/state/upload.heartbeat"
MAX_LOG_BYTES=${MAX_LOG_BYTES:-10485760}
LOG_RETENTION=${LOG_RETENTION:-7}
GCLOUD_TIMEOUT_S=${GCLOUD_TIMEOUT_S:-45}

CONVBIN_EXEC="/usr/local/bin/convbin"
GCLOUD_EXEC="/usr/bin/gcloud"
DATE_EXEC="/usr/bin/date"
TIMEOUT_EXEC="/usr/bin/timeout"

LOG_FILE="${LOG_DIR}/automation.log"

mkdir -p "${LOG_DIR}" "${RAW_DIR}" 2>/dev/null || true
mkdir -p "$(dirname "${HEARTBEAT_FILE}")" 2>/dev/null || true

# --- Resolve STATION_ID -----------------------------------------------------
STATION_ID=""
if [ -f "${STATION_CONF}" ]; then
    STATION_ID=$(grep -E '^[[:space:]]*STATION_ID[[:space:]]*=' "${STATION_CONF}" \
                 | head -n 1 | sed 's/^[[:space:]]*STATION_ID[[:space:]]*=[[:space:]]*//' | tr -d '"')
fi
[ -z "${STATION_ID}" ] && STATION_ID=$(hostname | tr '[:lower:]' '[:upper:]')

log() { echo "$(${DATE_EXEC} -u +"%Y-%m-%d %H:%M:%S UTC") [${STATION_ID}] $1" >> "${LOG_FILE}"; }

heartbeat() {
    printf '%s %s\n' "$(${DATE_EXEC} -u +%s)" "$1" > "${HEARTBEAT_FILE}" 2>/dev/null || true
}

rotate_log() {
    if [ -f "${LOG_FILE}" ]; then
        local size
        size=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo "0")
        if [ "${size}" -gt "${MAX_LOG_BYTES}" ]; then
            local i
            for i in $(seq $((LOG_RETENTION - 1)) -1 1); do
                [ -f "${LOG_FILE}.${i}" ] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
            done
            mv "${LOG_FILE}" "${LOG_FILE}.1"
            log "Log rotated (previous was ${size} bytes)"
        fi
    fi
}

# Hard-timeout wrapper around gcloud. Returns 0 on success, 124 on timeout,
# or the underlying gcloud exit code. The caller MUST distinguish 124 from
# other non-zero codes because a timeout is a connectivity signal, not a
# permanent failure.
gcloud_cmd() {
    ${TIMEOUT_EXEC} --kill-after=5 "${GCLOUD_TIMEOUT_S}" "${GCLOUD_EXEC}" "$@"
}

# --- Single-instance lock ---------------------------------------------------
if [ -f "${LOCK_FILE}" ]; then
    LOCK_PID=$(cat "${LOCK_FILE}" 2>/dev/null)
    if [ -n "${LOCK_PID}" ] && kill -0 "${LOCK_PID}" 2>/dev/null; then
        exit 0
    else
        rm -f "${LOCK_FILE}"
    fi
fi
echo $$ > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

rotate_log

# --- Ensure GCS auth --------------------------------------------------------
if [ -f "${GCS_KEY}" ]; then
    ACTIVE=$(gcloud_cmd auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
    if [ -z "${ACTIVE}" ]; then
        log "Re-activating GCS service account"
        gcloud_cmd auth activate-service-account --key-file="${GCS_KEY}" 2>/dev/null || \
            log "WARN: auth activation failed or timed out — continuing, uploads will likely fail this run"
    fi
fi

# --- Live-file detection threshold ------------------------------------------
# A rotation file is "closed" iff its mtime is older than MIN_CLOSED_AGE s.
# See rationale comment block below; MIN_CLOSED_AGE=60 is strictly greater
# than the maximum str2str write gap under healthy 1 Hz UBX.
NOW_EPOCH=$(${DATE_EXEC} -u +%s)
MIN_CLOSED_AGE=60

# --- Read APPROX POSITION XYZ ----------------------------------------------
read_ppp_xyz() {
    [ -f "${STATION_CONF}" ] || return 1
    local line
    line=$(grep -vE '^[[:space:]]*(#|$|[A-Za-z_][A-Za-z0-9_]*=)' "${STATION_CONF}" | head -n 1)
    [ -n "${line}" ] || return 1
    echo "${line}"
    return 0
}

PPP_LINE=$(read_ppp_xyz)
PPP_X=""; PPP_Y=""; PPP_Z=""
if [ -n "${PPP_LINE}" ]; then
    read -r PPP_X PPP_Y PPP_Z <<<"${PPP_LINE}"
fi

# --- Upload helper ----------------------------------------------------------
# Returns:
#   0 — uploaded and verified; local file deleted
#   1 — upload failed, local file retained
#   2 — upload timed out (network issue), local file retained
upload_and_verify() {
    local local_file="$1"
    local gcs_prefix="$2"
    local basename
    basename=$(basename "${local_file}")
    local gcs_path="${gcs_prefix}/${basename}"

    local upload_err rc
    upload_err=$(gcloud_cmd storage cp "${local_file}" "${gcs_path}" 2>&1)
    rc=$?
    if [ ${rc} -eq 124 ] || [ ${rc} -eq 137 ]; then
        log "TIMEOUT: upload exceeded ${GCLOUD_TIMEOUT_S}s for ${basename}"
        return 2
    fi
    if [ ${rc} -ne 0 ]; then
        log "ERROR: upload failed for ${basename} (rc=${rc}): ${upload_err}"
        return 1
    fi

    local verify_err
    verify_err=$(gcloud_cmd storage ls "${gcs_path}" 2>&1)
    rc=$?
    if [ ${rc} -eq 124 ] || [ ${rc} -eq 137 ]; then
        log "TIMEOUT: verification exceeded ${GCLOUD_TIMEOUT_S}s for ${gcs_path} — local file retained"
        return 2
    fi
    if [ ${rc} -ne 0 ]; then
        log "ERROR: verification failed for ${gcs_path} — local file retained: ${verify_err}"
        return 1
    fi

    rm -f "${local_file}"
    return 0
}

# Derive per-file GCS prefix from filename timestamp (so yesterday's
# leftovers go to yesterday's YYYY/DOY/ path, not today's).
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

# Ensure RINEX artefacts exist for ${base}; convbin only if missing/empty.
ensure_rinex() {
    local base="$1"
    local ubx="$2"
    local rinex_obs="${LOG_DIR}/${base}.obs"
    local rinex_nav="${LOG_DIR}/${base}.nav"

    # Alt-naming: some convbin versions write .rnx instead of .obs.
    if [ -f "${LOG_DIR}/${base}.rnx" ] && [ ! -f "${rinex_obs}" ]; then
        mv "${LOG_DIR}/${base}.rnx" "${rinex_obs}"
    fi

    if [ -s "${rinex_obs}" ] && [ -s "${rinex_nav}" ]; then
        return 0
    fi

    ${CONVBIN_EXEC} -v 3.03 -r ubx -d "${LOG_DIR}" -f 2 "${ubx}" >/dev/null 2>&1
    if [ -f "${LOG_DIR}/${base}.rnx" ] && [ ! -f "${rinex_obs}" ]; then
        mv "${LOG_DIR}/${base}.rnx" "${rinex_obs}"
    fi

    # Inject APPROX POSITION XYZ on first conversion only; sed is
    # idempotent so re-runs are safe either way.
    if [ -n "${PPP_X:-}" ] && [ -n "${PPP_Y:-}" ] && [ -n "${PPP_Z:-}" ] \
       && ! { [ "${PPP_X}" = "0.0000" ] && [ "${PPP_Y}" = "0.0000" ] && [ "${PPP_Z}" = "0.0000" ]; } \
       && [ -f "${rinex_obs}" ]; then
        sed -i "s/.*APPROX POSITION XYZ/$(printf "%14.4f%14.4f%14.4f" "${PPP_X}" "${PPP_Y}" "${PPP_Z}")                  APPROX POSITION XYZ/" "${rinex_obs}"
    fi

    [ -s "${rinex_obs}" ] || return 1
    return 0
}

# --- Process each closed rotation file --------------------------------------
for ubx in "${RAW_DIR}"/*.ubx; do
    [ -f "${ubx}" ] || continue
    base=$(basename "${ubx}" .ubx)

    # Live-file check: mtime within MIN_CLOSED_AGE seconds -> still being
    # written. Definite because 1 Hz UBX writes update mtime every ~1 s.
    mtime=$(stat -c%Y "${ubx}" 2>/dev/null || echo "0")
    age=$(( NOW_EPOCH - mtime ))
    if [ "${age}" -lt "${MIN_CLOSED_AGE}" ]; then
        continue
    fi

    # Skip zero-byte files (empty slot during a disk-full or str2str restart).
    if ! [ -s "${ubx}" ]; then
        log "Skipping empty UBX file ${base}.ubx"
        rm -f "${ubx}" "${RAW_DIR}/${base}.ubx.tag" 2>/dev/null
        continue
    fi

    heartbeat "processing ${base}"

    if ! ensure_rinex "${base}" "${ubx}"; then
        log "ERROR: RINEX production failed for ${base}"
        continue
    fi

    rinex_obs="${LOG_DIR}/${base}.obs"
    rinex_nav="${LOG_DIR}/${base}.nav"
    prefix=$(filename_to_gcs_prefix "${rinex_obs}")

    any_failed=0

    if [ -f "${rinex_obs}" ]; then
        upload_and_verify "${rinex_obs}" "${prefix}"; rc=$?
        if [ ${rc} -eq 0 ]; then
            log "Uploaded $(basename "${rinex_obs}") to ${prefix}/"
        else
            any_failed=1
        fi
    fi

    if [ -f "${rinex_nav}" ]; then
        upload_and_verify "${rinex_nav}" "${prefix}"; rc=$?
        if [ ${rc} -eq 0 ]; then
            log "Uploaded $(basename "${rinex_nav}") to ${prefix}/"
        else
            any_failed=1
        fi
    fi

    # Clean up raw UBX (and its .tag sidecar) only if both RINEX files
    # uploaded successfully AND no longer exist on disk (upload_and_verify
    # deletes on success).
    if [ "${any_failed}" -eq 0 ] && [ ! -f "${rinex_obs}" ] && [ ! -f "${rinex_nav}" ]; then
        rm -f "${ubx}" "${RAW_DIR}/${base}.ubx.tag"
        log "Slot ${base} complete"
    fi

    # Clean up any stray convbin side-files (.sbs, .lnx, etc).
    find "${LOG_DIR}" -maxdepth 1 \( -name "${base}.sbs" -o -name "${base}.lnx" \) -delete 2>/dev/null
done

# Also sweep leftover .obs/.nav files from previous worker runs that may have
# failed upload. These are never live (convbin writes atomically from closed
# UBX files), so no liveness check is needed.
for rinex in "${LOG_DIR}"/*.obs "${LOG_DIR}"/*.nav "${LOG_DIR}"/*.rnx; do
    [ -f "${rinex}" ] || continue
    prefix=$(filename_to_gcs_prefix "${rinex}")
    upload_and_verify "${rinex}" "${prefix}"; rc=$?
    if [ ${rc} -eq 0 ]; then
        log "Retry-uploaded $(basename "${rinex}") to ${prefix}/"
    fi
done

# Clean up orphaned .ubx.tag sidecars (the .tag remains if an older worker
# deleted the .ubx without deleting the tag, or if a previous crash left
# one behind). Only delete .tag files whose matching .ubx no longer exists
# and whose mtime is older than MIN_CLOSED_AGE so we never race with a
# live rotation file.
for tag in "${RAW_DIR}"/*.ubx.tag; do
    [ -f "${tag}" ] || continue
    ubx_path="${tag%.tag}"
    [ -f "${ubx_path}" ] && continue
    tag_mtime=$(stat -c%Y "${tag}" 2>/dev/null || echo "0")
    if [ $(( NOW_EPOCH - tag_mtime )) -ge "${MIN_CLOSED_AGE}" ]; then
        rm -f "${tag}"
    fi
done

# Heartbeat every run, regardless of whether anything was processed. The
# health endpoint's STALE_UPLOAD_HB_S threshold requires at least one
# heartbeat write within the worker's cron interval; idle minutes (most
# of the time — the worker only has work at rotation boundaries) must
# still check in.
heartbeat "idle"
