#!/bin/bash
# =============================================================================
# snareSAR GNSS Base Station — Idempotent deploy/install
#
# Continuous-capture architecture (2026-04-21 onward):
#   - gnss-capture.service           (resident str2str with ExecStartPre
#                                     receiver-config re-assert; continuous
#                                     UBX with 10-min rotation on UTC
#                                     :00/:10/:20/:30/:40/:50)
#   - gnss-health.service            (Tailscale-only /health HTTP endpoint)
#   - cron: gnss_upload_worker.sh    every 1 min (processes closed rotations)
#   - cron: gnss-watchdog.sh         every 1 min (restarts capture on stall)
#   - cron: gnss-disk-guard.sh       every 5 min (ring-buffer + low-disk)
#
# The standalone gnss-receiver.service (oneshot receiver config) is
# DEPRECATED in v1.0.0+. ExecStartPre inside gnss-capture.service now owns
# that responsibility. install.sh disables and masks the legacy unit if it
# is found on the target so operators do not keep seeing its stale
# failed-state in `systemctl status`.
#
# Safe to run on an already-configured host. Records the deployed version
# (from base_station/VERSION) to /home/xeroth/base_station/state/version.
#
# REQUIRES: A sibling payload/ directory and a VERSION file at repo root.
#
# USAGE:
#   Set STATION_ID on the FIRST run:
#     sudo ./install.sh --station MY_STATION
#   Subsequent runs preserve the existing STATION_ID in station.conf.
# =============================================================================

set -euo pipefail

DEST_SCRIPTS="/home/xeroth/base_station/scripts"
DEST_STATE="/home/xeroth/base_station/state"
DEST_LOGS="/home/xeroth/base_station/logs"
DEST_RAW="/home/xeroth/base_station/logs/raw"
DEST_STAGING="/home/xeroth/base_station/staging"
DEST_SYSTEMD="/etc/systemd/system"
USER_NAME="xeroth"
GROUP_NAME="xeroth"

STATION_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --station) STATION_OVERRIDE="$2"; shift 2;;
        --station=*) STATION_OVERRIDE="${1#*=}"; shift;;
        *) echo "Unknown arg: $1" >&2; exit 2;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="${HERE}/payload"
VERSION_FILE="${HERE}/VERSION"
[ -d "${PAYLOAD}" ] || { echo "ERROR: payload/ not found next to install.sh" >&2; exit 1; }
[ -f "${VERSION_FILE}" ] || { echo "ERROR: VERSION file missing at ${VERSION_FILE}" >&2; exit 1; }
VERSION=$(tr -d '[:space:]' < "${VERSION_FILE}")
if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
    echo "ERROR: invalid semver in VERSION: '${VERSION}'" >&2
    exit 1
fi
echo "Installing base_station v${VERSION}"

echo "[1/10] Create directories"
mkdir -p "${DEST_SCRIPTS}" "${DEST_STATE}" "${DEST_LOGS}" "${DEST_RAW}" "${DEST_STAGING}"
chown -R "${USER_NAME}:${GROUP_NAME}" /home/xeroth/base_station
chmod 0755 "${DEST_SCRIPTS}" "${DEST_STATE}" "${DEST_LOGS}" "${DEST_RAW}" "${DEST_STAGING}"

echo "[2/10] Deploy scripts"
install -m 0755 -o "${USER_NAME}" -g "${GROUP_NAME}" \
    "${PAYLOAD}/scripts/gnss_upload_worker.sh" "${DEST_SCRIPTS}/gnss_upload_worker.sh"
install -m 0755 -o "${USER_NAME}" -g "${GROUP_NAME}" \
    "${PAYLOAD}/scripts/ensure_receiver.py" "${DEST_SCRIPTS}/ensure_receiver.py"
install -m 0755 -o "${USER_NAME}" -g "${GROUP_NAME}" \
    "${PAYLOAD}/hardening/gnss-watchdog.sh" "${DEST_SCRIPTS}/gnss-watchdog.sh"
install -m 0755 -o "${USER_NAME}" -g "${GROUP_NAME}" \
    "${PAYLOAD}/hardening/gnss-disk-guard.sh" "${DEST_SCRIPTS}/gnss-disk-guard.sh"
install -m 0755 -o "${USER_NAME}" -g "${GROUP_NAME}" \
    "${PAYLOAD}/hardening/gnss_health.py" "${DEST_SCRIPTS}/gnss_health.py"
install -m 0755 -o "${USER_NAME}" -g "${GROUP_NAME}" \
    "${PAYLOAD}/scripts/gnss_update_agent.sh" "${DEST_SCRIPTS}/gnss_update_agent.sh"
# apply_update.sh is a narrowly-scoped sudo wrapper invoked by the update
# agent. Root-owned (not xeroth) so xeroth cannot tamper with the trusted
# entry point between OTA runs.
install -m 0755 -o root -g root \
    "${PAYLOAD}/scripts/apply_update.sh" "${DEST_SCRIPTS}/apply_update.sh"
# Retain the legacy manual utility for ad-hoc one-offs only — not wired
# into systemd or cron in v1.0.0+.
if [ -f "${PAYLOAD}/scripts/log_and_upload.sh" ]; then
    install -m 0755 -o "${USER_NAME}" -g "${GROUP_NAME}" \
        "${PAYLOAD}/scripts/log_and_upload.sh" "${DEST_SCRIPTS}/log_and_upload.sh"
fi

echo "[3/10] Ensure station.conf has STATION_ID"
STATION_CONF="${DEST_SCRIPTS}/station.conf"
if [ -n "${STATION_OVERRIDE}" ]; then
    if [ -f "${STATION_CONF}" ]; then
        if grep -qE '^[[:space:]]*STATION_ID[[:space:]]*=' "${STATION_CONF}"; then
            sed -i "s/^[[:space:]]*STATION_ID[[:space:]]*=.*/STATION_ID=${STATION_OVERRIDE}/" "${STATION_CONF}"
        else
            awk -v s="STATION_ID=${STATION_OVERRIDE}" '
                BEGIN{inserted=0}
                /^[[:space:]]*#/ && !inserted {print; next}
                !inserted {print s; print; inserted=1; next}
                {print}
            ' "${STATION_CONF}" > "${STATION_CONF}.new"
            mv "${STATION_CONF}.new" "${STATION_CONF}"
        fi
        chown "${USER_NAME}:${GROUP_NAME}" "${STATION_CONF}"
    else
        echo "ERROR: ${STATION_CONF} missing — create it with AUSPOS coords before re-running" >&2
        exit 1
    fi
else
    if [ ! -f "${STATION_CONF}" ] || ! grep -qE '^[[:space:]]*STATION_ID[[:space:]]*=' "${STATION_CONF}"; then
        echo "ERROR: ${STATION_CONF} missing or has no STATION_ID=. Use --station MY_STATION or MY_STATION" >&2
        exit 1
    fi
fi
STATION_ID=$(grep -E '^[[:space:]]*STATION_ID[[:space:]]*=' "${STATION_CONF}" \
             | head -n 1 | sed 's/^[[:space:]]*STATION_ID[[:space:]]*=[[:space:]]*//' | tr -d '"')
echo "    STATION_ID=${STATION_ID}"

echo "[4/10] Baud.conf"
BAUD_FILE="${DEST_SCRIPTS}/baud.conf"
if [ ! -f "${BAUD_FILE}" ]; then
    echo 115200 > "${BAUD_FILE}"
    chown "${USER_NAME}:${GROUP_NAME}" "${BAUD_FILE}"
fi

echo "[5/10] Deploy systemd units"
install -m 0644 "${PAYLOAD}/systemd/gnss-capture.service" \
    "${DEST_SYSTEMD}/gnss-capture.service"
install -m 0644 "${PAYLOAD}/systemd/gnss-health.service" \
    "${DEST_SYSTEMD}/gnss-health.service"

echo "[6/10] Retire legacy gnss-receiver.service"
# The oneshot was superseded by ExecStartPre in gnss-capture.service.
# Disable and mask any legacy unit so operators don't keep seeing its
# stale "failed (start-limit-hit)" state.
if systemctl list-unit-files gnss-receiver.service >/dev/null 2>&1; then
    systemctl disable gnss-receiver.service >/dev/null 2>&1 || true
    systemctl mask gnss-receiver.service    >/dev/null 2>&1 || true
    systemctl reset-failed gnss-receiver.service 2>/dev/null || true
fi
# Remove stale unit file on disk if present — masking alone leaves the
# file behind. Keep the symlink to /dev/null created by `systemctl mask`.
if [ -f "${DEST_SYSTEMD}/gnss-receiver.service" ] \
   && [ ! -L "${DEST_SYSTEMD}/gnss-receiver.service" ]; then
    rm -f "${DEST_SYSTEMD}/gnss-receiver.service"
fi

echo "[7/10] Systemd reload and enable"
systemctl daemon-reload
systemctl enable gnss-capture.service gnss-health.service >/dev/null
systemctl restart gnss-health.service
# gnss-capture is explicitly (re)started by the deploy so a running
# str2str picks up any unit-file changes. On a fresh install this is
# also the first-ever start.
systemctl restart gnss-capture.service

echo "[8/10] Install sudoers fragments"
# (a) watchdog: restart gnss-capture.service only
SUDOERS_WATCHDOG="/etc/sudoers.d/gnss-watchdog"
cat > "${SUDOERS_WATCHDOG}.new" <<EOF
# Allow xeroth to restart gnss-capture.service from the GNSS watchdog only.
${USER_NAME} ALL=(root) NOPASSWD: /bin/systemctl restart gnss-capture.service, /usr/bin/systemctl restart gnss-capture.service
EOF
if visudo -cf "${SUDOERS_WATCHDOG}.new" >/dev/null; then
    mv "${SUDOERS_WATCHDOG}.new" "${SUDOERS_WATCHDOG}"
    chmod 0440 "${SUDOERS_WATCHDOG}"
else
    echo "ERROR: watchdog sudoers fragment rejected by visudo" >&2
    rm -f "${SUDOERS_WATCHDOG}.new"
    exit 1
fi

# (b) OTA update agent: invoke apply_update.sh only. The wrapper itself
# validates the staging path, so this is not a `bash <anything>` escalation.
SUDOERS_UPDATE="/etc/sudoers.d/gnss-update-agent"
cat > "${SUDOERS_UPDATE}.new" <<EOF
# Allow xeroth to apply OTA updates via the root-owned apply_update.sh wrapper.
${USER_NAME} ALL=(root) NOPASSWD: ${DEST_SCRIPTS}/apply_update.sh /home/xeroth/base_station/staging/*/base_station
EOF
if visudo -cf "${SUDOERS_UPDATE}.new" >/dev/null; then
    mv "${SUDOERS_UPDATE}.new" "${SUDOERS_UPDATE}"
    chmod 0440 "${SUDOERS_UPDATE}"
else
    echo "ERROR: update-agent sudoers fragment rejected by visudo" >&2
    rm -f "${SUDOERS_UPDATE}.new"
    exit 1
fi

echo "[9/10] Install crontab"
# fs.protected_regular=2 (default on Debian 13) blocks even root from
# opening a non-root-owned file in /tmp. Do all crontab work as xeroth.
CRON_TMP=$(sudo -u "${USER_NAME}" mktemp -t snaresar-cron.XXXXXX)
trap 'sudo -u '"${USER_NAME}"' rm -f "'"${CRON_TMP}"'"' EXIT
sudo -u "${USER_NAME}" bash -c "crontab -l 2>/dev/null > '${CRON_TMP}' || true"
# Strip any pre-existing snareSAR lines (legacy + current).
sudo -u "${USER_NAME}" sed -i '/snareSAR GNSS base station/d' "${CRON_TMP}"
sudo -u "${USER_NAME}" sed -i '/log_and_upload\.sh/d' "${CRON_TMP}"
sudo -u "${USER_NAME}" sed -i '/gnss_upload_worker\.sh/d' "${CRON_TMP}"
sudo -u "${USER_NAME}" sed -i '/gnss-watchdog\.sh/d' "${CRON_TMP}"
sudo -u "${USER_NAME}" sed -i '/gnss-disk-guard\.sh/d' "${CRON_TMP}"
sudo -u "${USER_NAME}" sed -i '/gnss_update_agent\.sh/d' "${CRON_TMP}"
# Append canonical entries (v1.0.0 — continuous-capture, ring-buffer, OTA).
sudo -u "${USER_NAME}" bash -c "cat >> '${CRON_TMP}' <<'EOF'
# snareSAR GNSS base station — canonical cron (v1.0.0, continuous-capture + OTA)
* * * * * ${DEST_SCRIPTS}/gnss_upload_worker.sh
* * * * * ${DEST_SCRIPTS}/gnss-watchdog.sh
*/5 * * * * ${DEST_SCRIPTS}/gnss-disk-guard.sh
*/10 * * * * ${DEST_SCRIPTS}/gnss_update_agent.sh
EOF"
sudo -u "${USER_NAME}" crontab "${CRON_TMP}"
echo "    installed crontab for ${USER_NAME}"

echo "[10/10] Record deployed version and initialise channel state"
echo "${VERSION}" > "${DEST_STATE}/version"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") installed v${VERSION}" >> "${DEST_STATE}/version.log"
# Default release channel: pre-release versions (x.y.z-suffix) follow canary,
# clean semver versions follow stable. Only set the channel file if it does
# not already exist — operators may have pinned a station to a channel
# manually (e.g. MY_STATION=canary during field trials) and re-running install.sh
# must not clobber that choice.
if [ ! -f "${DEST_STATE}/channel" ]; then
    if [[ "${VERSION}" == *-* ]]; then
        DEFAULT_CHANNEL="canary"
    else
        DEFAULT_CHANNEL="stable"
    fi
    echo "${DEFAULT_CHANNEL}" > "${DEST_STATE}/channel"
fi
chown "${USER_NAME}:${GROUP_NAME}" \
    "${DEST_STATE}/version" "${DEST_STATE}/version.log" "${DEST_STATE}/channel"

CHANNEL_NOW=$(cat "${DEST_STATE}/channel" 2>/dev/null || echo "?")
echo
echo "Install complete"
echo "  STATION_ID: ${STATION_ID}"
echo "  Version:    ${VERSION}"
echo "  Channel:    ${CHANNEL_NOW}"
echo "  Scripts:    ${DEST_SCRIPTS}"
echo "  State:      ${DEST_STATE}"
echo "  Logs:       ${DEST_LOGS}"
echo "  Raw:        ${DEST_RAW}"
echo "  Staging:    ${DEST_STAGING}"
echo
echo "Verify:"
echo "  systemctl status gnss-capture.service gnss-health.service"
echo "  sudo -u ${USER_NAME} crontab -l"
echo "  ls -la ${DEST_RAW}/    # should show the currently-writing slot .ubx"
echo "  curl -s http://\$(tailscale ip -4):8080/health | python3 -m json.tool"
echo "  cat ${DEST_STATE}/version ${DEST_STATE}/channel"
echo "  tail -n 20 ${DEST_STATE}/updates.log  # OTA agent activity"
