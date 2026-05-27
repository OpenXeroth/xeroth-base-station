#!/bin/bash
# =============================================================================
# snareSAR GNSS Base Station — Ring-buffer disk guard
#
# Purpose:
#   Keep the logs partition from filling up during long network outages.
#   When free space falls below MIN_FREE_MB, purge the OLDEST .ubx / .obs /
#   .nav / .rnx / .sbs files — regardless of whether they sit at the top of
#   LOG_DIR or inside LOG_DIR/raw/ — until free space is above TARGET_FREE_MB.
#   Always preserves the currently-open slot and the PROTECT_SLOTS most
#   recent closed slots so fresh data is never dropped to keep stale data.
#
# The previous version restricted itself to `find -maxdepth 1` of LOG_DIR
# and therefore never saw the raw UBX files that str2str writes into
# LOG_DIR/raw/. Under a real outage that guard would have been a no-op and
# the disk would have filled. This version covers both directories.
#
# Cron: */5 * * * * /home/xeroth/base_station/scripts/gnss-disk-guard.sh
# =============================================================================

set -u

LOG_DIR="/home/xeroth/base_station/logs"
RAW_DIR="${LOG_DIR}/raw"
LOG_FILE="${LOG_DIR}/disk-guard.log"

MIN_FREE_MB=${MIN_FREE_MB:-2048}          # Start purging below 2 GiB free
TARGET_FREE_MB=${TARGET_FREE_MB:-4096}    # Keep purging until 4 GiB free
PROTECT_SLOTS=${PROTECT_SLOTS:-3}         # Protect the N newest slots (by mtime)
PROTECT_ACTIVE_AGE_S=${PROTECT_ACTIVE_AGE_S:-60}   # Files modified within this are "active"
MAX_LOG_BYTES=${MAX_LOG_BYTES:-5242880}   # 5 MiB per log file
LOG_RETENTION=${LOG_RETENTION:-7}         # Keep .1 .. .7

mkdir -p "${LOG_DIR}" "${RAW_DIR}" 2>/dev/null || true

log() {
    echo "$(date -u +"%Y-%m-%d %H:%M:%S UTC") $1" >> "${LOG_FILE}"
}

rotate_guard_log() {
    if [ -f "${LOG_FILE}" ]; then
        local size
        size=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo "0")
        if [ "${size}" -gt "${MAX_LOG_BYTES}" ]; then
            local i
            for i in $(seq $((LOG_RETENTION - 1)) -1 1); do
                [ -f "${LOG_FILE}.${i}" ] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
            done
            mv "${LOG_FILE}" "${LOG_FILE}.1"
        fi
    fi
}

free_mb() {
    df -BM --output=avail "${LOG_DIR}" 2>/dev/null | awk 'NR==2 {gsub("M",""); print $1}'
}

rotate_guard_log

AVAIL=$(free_mb)
if ! [[ "${AVAIL}" =~ ^[0-9]+$ ]]; then
    log "ERROR: could not determine free space for ${LOG_DIR}"
    exit 1
fi

if [ "${AVAIL}" -ge "${MIN_FREE_MB}" ]; then
    exit 0
fi

log "LOW_DISK: ${AVAIL} MB free (< ${MIN_FREE_MB}), starting purge (target ${TARGET_FREE_MB} MB)"

NOW=$(date -u +%s)

# --- Build candidate list ----------------------------------------------------
# Collect every GNSS data file in LOG_DIR and LOG_DIR/raw at maxdepth 1
# (i.e. direct children, no deeper). Exclude anything whose mtime is newer
# than NOW - PROTECT_ACTIVE_AGE_S (the currently-writing slot). After that
# protection, protect the PROTECT_SLOTS newest files so fresh data is
# preserved even when the card is full of backlog.
CANDIDATE_LIST=$(
    for d in "${LOG_DIR}" "${RAW_DIR}"; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -type f \
             \( -name "*.ubx" -o -name "*.ubx.tag" -o -name "*.obs" \
                -o -name "*.rnx" -o -name "*.nav" -o -name "*.sbs" \) \
             -printf '%T@ %p\n' 2>/dev/null
    done | awk -v now="${NOW}" -v active_age="${PROTECT_ACTIVE_AGE_S}" '
        $1 + 0 + active_age < now { print }
    ' | sort -n
)

TOTAL_CANDIDATES=$(echo "${CANDIDATE_LIST}" | grep -c .)
if [ "${TOTAL_CANDIDATES}" -eq 0 ]; then
    log "PURGE_ABORT: no candidate files (disk full of non-GNSS content?)"
    AVAIL_FINAL=$(free_mb)
    log "PURGE_DONE: 0 files removed, ${AVAIL_FINAL} MB free"
    exit 0
fi

# --- Apply newest-slot protection -------------------------------------------
# Drop the PROTECT_SLOTS newest entries from the purge list (they sit at the
# tail of the mtime-sorted list).
PURGE_COUNT=$(( TOTAL_CANDIDATES - PROTECT_SLOTS ))
if [ "${PURGE_COUNT}" -le 0 ]; then
    log "PURGE_ABORT: only ${TOTAL_CANDIDATES} candidates, PROTECT_SLOTS=${PROTECT_SLOTS} — nothing to purge without dropping protected data"
    AVAIL_FINAL=$(free_mb)
    log "PURGE_DONE: 0 files removed, ${AVAIL_FINAL} MB free"
    exit 0
fi

PURGED=0
while IFS= read -r line; do
    [ -n "${line}" ] || continue
    [ "${PURGED}" -ge "${PURGE_COUNT}" ] && break

    FILE=$(echo "${line}" | cut -d' ' -f2-)
    MT=$(echo "${line}" | cut -d' ' -f1 | cut -d. -f1)
    [ -f "${FILE}" ] || continue

    SIZE=$(stat -c%s "${FILE}" 2>/dev/null || echo 0)
    rm -f "${FILE}"
    PURGED=$((PURGED + 1))
    log "PURGED: ${FILE} (${SIZE} bytes, mtime $(date -u -d @${MT} +%FT%TZ))"

    AVAIL=$(free_mb)
    if [[ "${AVAIL}" =~ ^[0-9]+$ ]] && [ "${AVAIL}" -ge "${TARGET_FREE_MB}" ]; then
        break
    fi
done <<< "${CANDIDATE_LIST}"

AVAIL_FINAL=$(free_mb)
log "PURGE_DONE: ${PURGED} files removed, ${AVAIL_FINAL} MB free (protected ${PROTECT_SLOTS} newest + active slot)"
