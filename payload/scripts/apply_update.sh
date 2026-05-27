#!/bin/bash
# =============================================================================
# snareSAR GNSS Base Station — update application wrapper
#
# Purpose: give gnss_update_agent.sh a narrowly-scoped sudo entry point so
# that the sudoers fragment does not have to whitelist `bash <anything>`.
#
# Contract (kept deliberately stable so that future OTA updates remain able
# to invoke the CURRENTLY-installed version of this wrapper):
#
#     sudo apply_update.sh <staging_root>
#
# where <staging_root> is expected to be
#     /home/xeroth/base_station/staging/<VERSION>/base_station
# and must contain:
#     - install.sh
#     - VERSION           matching the <VERSION> segment above
#     - payload/          (populated)
#
# The wrapper:
#   1. Validates the argument against the staging path regex — no traversal,
#      no directories outside /home/xeroth/base_station/staging/.
#   2. Reads STATION_ID from /home/xeroth/base_station/scripts/station.conf
#      (the authoritative, already-installed copy — we do NOT trust the
#      staging copy for this).
#   3. Execs `bash <staging>/install.sh --station <STATION_ID>`.
#
# This contract is frozen. Do not change argument shape without a flag-day
# migration because older installed wrappers are what get invoked when the
# OTA agent applies a new release.
# =============================================================================

set -u

STAGE_BASE="/home/xeroth/base_station/staging"
STATION_CONF="/home/xeroth/base_station/scripts/station.conf"

if [ "$(id -u)" -ne 0 ]; then
    echo "apply_update.sh: must run as root" >&2
    exit 2
fi

if [ $# -ne 1 ]; then
    echo "usage: apply_update.sh <staging_root>" >&2
    exit 2
fi

STAGING_ROOT="$1"

# Reject path traversal and anything not under STAGE_BASE.
case "${STAGING_ROOT}" in
    *..*) echo "apply_update.sh: staging root contains '..'" >&2; exit 2;;
esac

if ! [[ "${STAGING_ROOT}" =~ ^${STAGE_BASE}/[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?/base_station$ ]]; then
    echo "apply_update.sh: staging root does not match expected shape: ${STAGING_ROOT}" >&2
    exit 2
fi

if [ ! -d "${STAGING_ROOT}" ]; then
    echo "apply_update.sh: staging root does not exist: ${STAGING_ROOT}" >&2
    exit 2
fi

if [ ! -f "${STAGING_ROOT}/install.sh" ] || [ ! -f "${STAGING_ROOT}/VERSION" ]; then
    echo "apply_update.sh: staging root missing install.sh or VERSION" >&2
    exit 2
fi

# Extract the <VERSION> segment from the path and confirm the tarball's
# VERSION file matches it. Defence in depth against someone planting a
# mismatched tarball under a legitimate-looking directory.
PATH_VERSION="${STAGING_ROOT#${STAGE_BASE}/}"
PATH_VERSION="${PATH_VERSION%/base_station}"
FILE_VERSION=$(tr -d '[:space:]' < "${STAGING_ROOT}/VERSION")
if [ "${PATH_VERSION}" != "${FILE_VERSION}" ]; then
    echo "apply_update.sh: VERSION file (${FILE_VERSION}) does not match staging path (${PATH_VERSION})" >&2
    exit 2
fi

# Pull STATION_ID from the already-installed station.conf, not from the
# staging copy. install.sh does not require --station when station.conf
# already has STATION_ID=, but we pass it explicitly to avoid any chance
# of a silent default.
if [ ! -f "${STATION_CONF}" ]; then
    echo "apply_update.sh: ${STATION_CONF} missing" >&2
    exit 2
fi
STATION_ID=$(grep -E '^[[:space:]]*STATION_ID[[:space:]]*=' "${STATION_CONF}" \
             | head -n 1 | sed 's/^[[:space:]]*STATION_ID[[:space:]]*=[[:space:]]*//' | tr -d '"')
if [ -z "${STATION_ID}" ]; then
    echo "apply_update.sh: no STATION_ID in ${STATION_CONF}" >&2
    exit 2
fi

exec /bin/bash "${STAGING_ROOT}/install.sh" --station "${STATION_ID}"
