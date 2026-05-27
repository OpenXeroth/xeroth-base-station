#!/bin/bash
# =============================================================================
# snareSAR GNSS Base Station — OTA update agent
#
# Pull-based auto-updater. Each station reads its release channel from
#   /home/xeroth/base_station/state/channel   (default: stable)
# and polls the corresponding pointer:
#   gs://xeroth-base-stations-releases/base_station/channels/${CHANNEL}.version
# When the pointer names a version different from what is currently
# installed (/home/xeroth/base_station/state/version), the agent:
#   1. Downloads the tarball + .sha256 sidecar
#   2. Verifies the SHA-256
#   3. Extracts to a staging directory
#   4. Invokes the packaged install.sh with the existing STATION_ID
#   5. Checks the post-install /health endpoint
#   6. On any failure, logs the diagnostic and leaves the previous
#      installation running unchanged.
#
# Pull-based is the only safe model for stations on intermittent links
# behind NAT. The station is the only actor that knows its own state and
# connectivity window.
#
# Cron: */10 * * * * /home/xeroth/base_station/scripts/gnss_update_agent.sh
# =============================================================================

set -u

RELEASE_BUCKET="gs://xeroth-base-stations-releases"
STATE_DIR="/home/xeroth/base_station/state"
CHANNEL_FILE="${STATE_DIR}/channel"
VERSION_FILE="${STATE_DIR}/version"
TARGET_FILE="${STATE_DIR}/target_version"
ATTEMPT_FILE="${STATE_DIR}/last_update_attempt"
RESULT_FILE="${STATE_DIR}/last_update_result"
UPDATE_LOG="${STATE_DIR}/updates.log"
LOCK_FILE="/tmp/gnss-update-agent.lock"
STAGE_ROOT="/home/xeroth/base_station/staging"
STATION_CONF="/home/xeroth/base_station/scripts/station.conf"
HEALTH_URL_DEFAULT="http://localhost:8080/health"

GCLOUD_EXEC="/usr/bin/gcloud"
TIMEOUT_EXEC="/usr/bin/timeout"
SHA256SUM_EXEC="/usr/bin/sha256sum"
CURL_EXEC="/usr/bin/curl"
TAR_EXEC="/bin/tar"
GCLOUD_TIMEOUT_S=${GCLOUD_TIMEOUT_S:-60}

mkdir -p "$(dirname "${UPDATE_LOG}")" "${STAGE_ROOT}" 2>/dev/null || true

log() {
    local line
    line="$(date -u +"%Y-%m-%d %H:%M:%S UTC") $1"
    echo "${line}" >> "${UPDATE_LOG}"
    # Rotate at 5 MiB, keep 7 generations.
    local sz
    sz=$(stat -c%s "${UPDATE_LOG}" 2>/dev/null || echo 0)
    if [ "${sz}" -gt 5242880 ]; then
        local i
        for i in 6 5 4 3 2 1; do
            [ -f "${UPDATE_LOG}.${i}" ] && mv "${UPDATE_LOG}.${i}" "${UPDATE_LOG}.$((i+1))"
        done
        mv "${UPDATE_LOG}" "${UPDATE_LOG}.1"
        echo "${line}" >> "${UPDATE_LOG}"
    fi
}

gcloud_cmd() {
    ${TIMEOUT_EXEC} --kill-after=5 "${GCLOUD_TIMEOUT_S}" "${GCLOUD_EXEC}" "$@"
}

# Overwrite a state file atomically so /health never reads a partial value.
write_state() {
    local path="$1"
    local value="$2"
    local tmp="${path}.tmp.$$"
    printf '%s\n' "${value}" > "${tmp}" && mv "${tmp}" "${path}"
}

# Record the result of this run for /health and exit with the given code.
finish() {
    local result="$1"
    local rc="$2"
    write_state "${RESULT_FILE}" "${result}"
    exit "${rc}"
}

# --- Single-instance lock ---------------------------------------------------
if [ -f "${LOCK_FILE}" ]; then
    LOCK_PID=$(cat "${LOCK_FILE}" 2>/dev/null)
    if [ -n "${LOCK_PID}" ] && kill -0 "${LOCK_PID}" 2>/dev/null; then
        exit 0
    fi
    rm -f "${LOCK_FILE}"
fi
echo $$ > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

# Record attempt timestamp for /health — every run, regardless of outcome.
write_state "${ATTEMPT_FILE}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- Resolve STATION_ID + channel -------------------------------------------
STATION_ID=""
if [ -f "${STATION_CONF}" ]; then
    STATION_ID=$(grep -E '^[[:space:]]*STATION_ID[[:space:]]*=' "${STATION_CONF}" \
                 | head -n 1 | sed 's/^[[:space:]]*STATION_ID[[:space:]]*=[[:space:]]*//' | tr -d '"')
fi
[ -z "${STATION_ID}" ] && STATION_ID=$(hostname | tr '[:lower:]' '[:upper:]')

CHANNEL="stable"
if [ -f "${CHANNEL_FILE}" ]; then
    CHANNEL=$(tr -d '[:space:]' < "${CHANNEL_FILE}" || echo "stable")
fi
[ -z "${CHANNEL}" ] && CHANNEL="stable"

CURRENT_VERSION="none"
if [ -f "${VERSION_FILE}" ]; then
    CURRENT_VERSION=$(tr -d '[:space:]' < "${VERSION_FILE}")
fi

# --- Fetch channel pointer --------------------------------------------------
POINTER_URL="${RELEASE_BUCKET}/base_station/channels/${CHANNEL}.version"
TARGET_VERSION=$(gcloud_cmd storage cat "${POINTER_URL}" 2>/dev/null | tr -d '[:space:]')
if [ -z "${TARGET_VERSION}" ]; then
    log "POLL_FAILED: could not read ${POINTER_URL} (channel=${CHANNEL}, current=${CURRENT_VERSION})"
    finish "poll_failed" 0
fi
if ! [[ "${TARGET_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
    log "POLL_INVALID: channel pointer returned '${TARGET_VERSION}'"
    finish "poll_invalid" 0
fi

# Record the pointer value so /health can show what the fleet is being
# pointed at, whether or not we decide to install it.
write_state "${TARGET_FILE}" "${TARGET_VERSION}"

if [ "${TARGET_VERSION}" = "${CURRENT_VERSION}" ]; then
    # Nothing to do. Silent no-op.
    finish "up_to_date" 0
fi

log "UPDATE_CHECK: station=${STATION_ID} channel=${CHANNEL} current=${CURRENT_VERSION} target=${TARGET_VERSION}"

# --- Download tarball + checksum --------------------------------------------
WORK_DIR="${STAGE_ROOT}/${TARGET_VERSION}"
TARBALL="base_station-v${TARGET_VERSION}.tar.gz"
REMOTE_DIR="${RELEASE_BUCKET}/base_station/v${TARGET_VERSION}"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

if ! gcloud_cmd storage cp "${REMOTE_DIR}/${TARBALL}" "${WORK_DIR}/${TARBALL}" >/dev/null 2>&1; then
    log "DOWNLOAD_FAILED: ${REMOTE_DIR}/${TARBALL}"
    rm -rf "${WORK_DIR}"
    finish "download_failed" 1
fi
if ! gcloud_cmd storage cp "${REMOTE_DIR}/${TARBALL}.sha256" "${WORK_DIR}/${TARBALL}.sha256" >/dev/null 2>&1; then
    log "DOWNLOAD_FAILED: ${REMOTE_DIR}/${TARBALL}.sha256"
    rm -rf "${WORK_DIR}"
    finish "download_failed" 1
fi

EXPECTED=$(tr -d '[:space:]' < "${WORK_DIR}/${TARBALL}.sha256")
ACTUAL=$(${SHA256SUM_EXEC} "${WORK_DIR}/${TARBALL}" | awk '{print $1}')
if [ "${EXPECTED}" != "${ACTUAL}" ]; then
    log "SHA256_MISMATCH: expected=${EXPECTED} actual=${ACTUAL}"
    rm -rf "${WORK_DIR}"
    finish "sha256_mismatch" 1
fi
log "DOWNLOAD_OK: ${TARBALL} (sha256 verified)"

# --- Extract ----------------------------------------------------------------
if ! ${TAR_EXEC} -xzf "${WORK_DIR}/${TARBALL}" -C "${WORK_DIR}"; then
    log "EXTRACT_FAILED: ${TARBALL}"
    rm -rf "${WORK_DIR}"
    finish "extract_failed" 1
fi

EXTRACTED_ROOT="${WORK_DIR}/base_station"
if [ ! -f "${EXTRACTED_ROOT}/install.sh" ] || [ ! -f "${EXTRACTED_ROOT}/VERSION" ]; then
    log "EXTRACT_INVALID: expected base_station/install.sh and VERSION in tarball"
    rm -rf "${WORK_DIR}"
    finish "extract_invalid" 1
fi

EXTRACTED_VERSION=$(tr -d '[:space:]' < "${EXTRACTED_ROOT}/VERSION")
if [ "${EXTRACTED_VERSION}" != "${TARGET_VERSION}" ]; then
    log "VERSION_MISMATCH: tarball VERSION=${EXTRACTED_VERSION} != target=${TARGET_VERSION}"
    rm -rf "${WORK_DIR}"
    finish "version_mismatch" 1
fi

# --- Run install.sh via apply_update.sh wrapper -----------------------------
# The wrapper is narrowly whitelisted in /etc/sudoers.d/gnss-update-agent so
# that the agent does not need `bash <anything>` sudo rights. We invoke the
# ALREADY-INSTALLED wrapper (at ${APPLY_UPDATE}), not the one in the tarball
# — the installed one is the trusted one, and it in turn execs the staging
# install.sh.
APPLY_UPDATE="/home/xeroth/base_station/scripts/apply_update.sh"
if [ ! -x "${APPLY_UPDATE}" ]; then
    log "APPLY_UPDATE_MISSING: ${APPLY_UPDATE} not executable — cannot apply update"
    finish "apply_update_missing" 1
fi

log "INSTALL_BEGIN: v${TARGET_VERSION}"
INSTALL_OUT="${WORK_DIR}/install.out"
# shellcheck disable=SC2024
# The redirect is intentionally evaluated by xeroth's shell, not by the
# sudo'd process — WORK_DIR is xeroth-owned so this is correct, and we
# want install.out readable by the agent for the HEALTH_CHECK branch.
if ! sudo -n "${APPLY_UPDATE}" "${EXTRACTED_ROOT}" > "${INSTALL_OUT}" 2>&1; then
    log "INSTALL_FAILED: see ${INSTALL_OUT}"
    # Keep the staging dir so an operator can inspect install.out.
    finish "install_failed" 1
fi
log "INSTALL_OK: v${TARGET_VERSION}"

# --- Post-install health probe ----------------------------------------------
# install.sh restarts gnss-health.service and gnss-capture.service; give
# the python HTTP server a moment to re-bind before probing.
sleep 5
HEALTH_JSON=$(${TIMEOUT_EXEC} 5 ${CURL_EXEC} -sS "${HEALTH_URL_DEFAULT}" 2>/dev/null || true)
if ! echo "${HEALTH_JSON}" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    log "HEALTH_CHECK_FAILED: ${HEALTH_URL_DEFAULT} did not return status=ok after install"
    # Don't auto-rollback yet — a permanent failure here requires
    # operator attention. Record it loudly and leave the install in
    # place (install.sh has already started the new services).
    finish "health_check_failed" 1
fi
log "HEALTH_OK: v${TARGET_VERSION} running and healthy"

# --- Clean up older staging dirs (keep the most recent 3) -------------------
ls -1dt "${STAGE_ROOT}"/*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf

finish "ok" 0
