#!/bin/bash
# =============================================================================
# snareSAR GNSS Base Station — Watchdog (continuous-capture model)
#
# Runs every minute. In the continuous-capture architecture the primary
# responsibility is: if gnss-capture.service is supposed to be producing
# UBX bytes into RAW_DIR but no file has been written recently, restart
# gnss-capture.service. systemd's own Restart=on-failure already covers
# str2str crashes; this watchdog covers the nastier case where str2str is
# alive but the serial feed has silently stalled (e.g. FTDI hang, receiver
# hang, buffer wedge).
#
# Design note (2026-04-24): the previous implementation computed a
# "canonical slot name" like 202604240800.ubx from the current 10-min UTC
# boundary and restarted the capture if that exact file was stale or
# missing. But str2str names its first-after-start file by the current
# minute at file-open time (e.g. 202604240805.ubx when started at 08:05),
# not by the 10-min boundary. The two names only coincide when str2str
# happens to start exactly on a 10-min boundary, so the old logic produced
# a spurious restart every 3 minutes (= the backoff interval), which then
# created another mismatched filename, perpetuating the loop. Fixed to
# check the newest .ubx in RAW_DIR regardless of filename — if any .ubx
# is being written within CAPTURE_STALL_SECONDS, capture is alive.
#
# Separately, any leftover /tmp/gnss-cycle.lock from the old cron-based
# architecture is removed on first sight.
#
# Cron: * * * * * /home/xeroth/base_station/scripts/gnss-watchdog.sh
# =============================================================================

set -u

RAW_DIR="/home/xeroth/base_station/logs/raw"
LEGACY_LOCK="/tmp/gnss-cycle.lock"
LOG_DIR="/home/xeroth/base_station/logs"
LOG_FILE="${LOG_DIR}/watchdog.log"
CAPTURE_UNIT="gnss-capture.service"
CAPTURE_STALL_SECONDS=60          # if newest .ubx mtime older than this, restart
RESTART_BACKOFF_SECONDS=180       # don't restart more than once per 3 minutes

mkdir -p "${LOG_DIR}" 2>/dev/null || true

log() {
    echo "$(date -u +"%Y-%m-%d %H:%M:%S UTC") $1" >> "${LOG_FILE}"
}

LOG_RETENTION=${LOG_RETENTION:-7}

rotate_watchdog_log() {
    if [ -f "${LOG_FILE}" ]; then
        local size
        size=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo "0")
        if [ "${size}" -gt 5242880 ]; then   # 5 MiB
            local i
            for i in $(seq $((LOG_RETENTION - 1)) -1 1); do
                [ -f "${LOG_FILE}.${i}" ] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
            done
            mv "${LOG_FILE}" "${LOG_FILE}.1"
        fi
    fi
}

rotate_watchdog_log

NOW=$(date -u +%s)

# --- Remove legacy cron-based cycle lock if present (cron path is disabled) ---
if [ -f "${LEGACY_LOCK}" ]; then
    log "LEGACY_LOCK: removing ${LEGACY_LOCK} (continuous-capture architecture)"
    rm -f "${LEGACY_LOCK}" 2>/dev/null || true
fi

# --- Capture service must be active ---
CAPTURE_STATE=$(systemctl is-active "${CAPTURE_UNIT}" 2>/dev/null || true)
if [ "${CAPTURE_STATE}" != "active" ]; then
    log "CAPTURE_INACTIVE: ${CAPTURE_UNIT} state=${CAPTURE_STATE}; systemd Restart= handles this — no action"
    exit 0
fi

# --- Capture freshness check (filename-agnostic) ---
# Find the most-recently-modified .ubx file in RAW_DIR. If its mtime is
# fresher than CAPTURE_STALL_SECONDS, capture is alive regardless of
# whether its filename matches any canonical slot name.
NEWEST_UBX=$(ls -t "${RAW_DIR}"/*.ubx 2>/dev/null | head -1)

RESTART_NEEDED=0
STALL_REASON=""

if [ -z "${NEWEST_UBX}" ]; then
    RESTART_NEEDED=1
    STALL_REASON="no .ubx files present in ${RAW_DIR}"
else
    MTIME=$(stat -c%Y "${NEWEST_UBX}" 2>/dev/null || echo "0")
    AGE=$(( NOW - MTIME ))
    if [ "${AGE}" -gt "${CAPTURE_STALL_SECONDS}" ]; then
        RESTART_NEEDED=1
        STALL_REASON="newest .ubx (${NEWEST_UBX##*/}) mtime ${AGE}s old (> ${CAPTURE_STALL_SECONDS}s)"
    fi
fi

if [ "${RESTART_NEEDED}" -eq 1 ]; then
    # Back-off: don't restart again if last watchdog restart was recent.
    LAST_RESTART_MARKER="/home/xeroth/base_station/state/watchdog.last_restart"
    LAST_RESTART_EPOCH=0
    if [ -f "${LAST_RESTART_MARKER}" ]; then
        LAST_RESTART_EPOCH=$(cat "${LAST_RESTART_MARKER}" 2>/dev/null || echo "0")
    fi
    if ! [[ "${LAST_RESTART_EPOCH}" =~ ^[0-9]+$ ]]; then
        LAST_RESTART_EPOCH=0
    fi
    if [ $(( NOW - LAST_RESTART_EPOCH )) -lt "${RESTART_BACKOFF_SECONDS}" ]; then
        log "CAPTURE_STALL_BACKOFF: ${STALL_REASON}; last restart $(( NOW - LAST_RESTART_EPOCH ))s ago"
        exit 0
    fi

    log "CAPTURE_STALL: ${STALL_REASON} — restarting ${CAPTURE_UNIT}"
    if sudo -n systemctl restart "${CAPTURE_UNIT}" 2>/dev/null; then
        echo "${NOW}" > "${LAST_RESTART_MARKER}" 2>/dev/null || true
        log "CAPTURE_RESTARTED: ${CAPTURE_UNIT}"
    else
        log "CAPTURE_RESTART_FAILED: sudo systemctl restart ${CAPTURE_UNIT} returned non-zero"
    fi
fi
