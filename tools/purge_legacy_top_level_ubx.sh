#!/bin/bash
# =============================================================================
# purge_legacy_top_level_ubx.sh
#
# Remove pre-continuous-capture UBX files that may still be sitting at the
# top of /home/xeroth/base_station/logs/. These date from the cron-based
# 480-second architecture that wrote directly into LOG_DIR. The v1.0.0
# continuous-capture architecture writes only into LOG_DIR/raw/, and the
# upload worker is authoritative for anything in LOG_DIR itself — so any
# .ubx / .obs / .nav / .rnx / .sbs / .ubx.tag at LOG_DIR's top level is
# either:
#   (a) a left-over from a previous architecture, OR
#   (b) a RINEX product that the upload worker will re-upload on its own
#       next cron tick.
#
# (a) is what we purge here. (b) we leave alone by default — the worker's
# "sweep leftover .obs/.nav" block handles them cleanly and deleting them
# out from under an in-flight upload would be a regression.
#
# Usage:
#   base_station/tools/purge_legacy_top_level_ubx.sh [--dry-run] [--force]
#
# Default is dry-run. Pass --force to actually delete.
#
# Safe to run while services are live — only touches files older than
# PURGE_MIN_AGE_S (default 3600) to avoid any race with an in-flight
# conversion by the upload worker.
# =============================================================================

set -u

LOG_DIR="/home/xeroth/base_station/logs"
PURGE_MIN_AGE_S="${PURGE_MIN_AGE_S:-3600}"

MODE="dry-run"
for arg in "$@"; do
    case "${arg}" in
        --dry-run) MODE="dry-run";;
        --force)   MODE="force";;
        --help|-h)
            sed -n '3,30p' "$0"
            exit 0
            ;;
        *) echo "Unknown arg: ${arg}" >&2; exit 2;;
    esac
done

if [ ! -d "${LOG_DIR}" ]; then
    echo "LOG_DIR not present: ${LOG_DIR}" >&2
    exit 1
fi

NOW=$(date -u +%s)
STATION_HOST=$(hostname)
echo "purge_legacy_top_level_ubx.sh on ${STATION_HOST} (mode=${MODE}, min_age=${PURGE_MIN_AGE_S}s)"

CANDIDATES=()
while IFS= read -r -d '' f; do
    mtime=$(stat -c%Y "${f}" 2>/dev/null || echo 0)
    age=$(( NOW - mtime ))
    if [ "${age}" -lt "${PURGE_MIN_AGE_S}" ]; then
        continue
    fi
    CANDIDATES+=("${f}")
done < <(find "${LOG_DIR}" -maxdepth 1 -type f -name "*.ubx" -print0)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    echo "No candidate legacy UBX files at top of ${LOG_DIR}"
    exit 0
fi

echo "Found ${#CANDIDATES[@]} legacy .ubx at top of ${LOG_DIR}:"
TOTAL_BYTES=0
for f in "${CANDIDATES[@]}"; do
    sz=$(stat -c%s "${f}" 2>/dev/null || echo 0)
    TOTAL_BYTES=$(( TOTAL_BYTES + sz ))
    mt=$(stat -c%Y "${f}" 2>/dev/null || echo 0)
    printf '  %s (%d bytes, mtime %s)\n' \
        "${f}" "${sz}" "$(date -u -d @"${mt}" +%FT%TZ)"
done
TOTAL_MB=$(( TOTAL_BYTES / 1048576 ))
echo "Total: ${TOTAL_BYTES} bytes (${TOTAL_MB} MiB)"

if [ "${MODE}" = "dry-run" ]; then
    echo "Dry-run. Re-run with --force to delete."
    exit 0
fi

# Delete also the matching .ubx.tag sidecar, if any, and any .sbs side-files.
REMOVED=0
for f in "${CANDIDATES[@]}"; do
    rm -f "${f}" "${f}.tag" "${f%.ubx}.sbs" "${f%.ubx}.lnx" 2>/dev/null || true
    REMOVED=$(( REMOVED + 1 ))
done
echo "Removed ${REMOVED} legacy .ubx files (+ matching .tag/.sbs/.lnx side-files)"
