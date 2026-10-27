#!/usr/bin/env bats
# =============================================================================
# install.sh — structural tests
#
# install.sh is the single on-station deploy entry point, invoked both by
# an operator's first-run `sudo ./install.sh --station MY_STATION` and by the
# OTA apply_update.sh wrapper. These tests pin the invariants that make
# repeated unattended application safe:
#   - Idempotency: re-running MUST NOT wipe STATION_ID/station.conf.
#   - OTA integration: installs apply_update.sh as root-owned, installs
#     the sudoers fragment for the update agent, drops the cron entry.
#   - Legacy cleanup: disables AND masks gnss-receiver.service so operators
#     never see its stale failed state.
#   - Version recording: writes base_station/VERSION into state/version.
# =============================================================================

setup() {
    INSTALL="${BATS_TEST_DIRNAME}/../../install.sh"
    [ -x "$INSTALL" ] || [ -f "$INSTALL" ]
}

@test "install.sh validates VERSION file against semver" {
    grep -q 'VERSION=\$(tr -d' "$INSTALL"
    grep -qE 'VERSION.*=~.*\^\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+' "$INSTALL"
}

@test "install.sh disables AND masks legacy gnss-receiver.service" {
    grep -q 'systemctl disable gnss-receiver.service' "$INSTALL"
    grep -q 'systemctl mask gnss-receiver.service' "$INSTALL"
}

@test "install.sh installs apply_update.sh as root-owned" {
    grep -q '"\${PAYLOAD}/scripts/apply_update.sh" "\${DEST_SCRIPTS}/apply_update.sh"' "$INSTALL"
    # Specifically: -o root -g root. xeroth must not be able to tamper
    # with the trusted entry point between OTA runs.
    grep -q '\-o root -g root' "$INSTALL"
}

@test "install.sh installs gnss-update-agent sudoers fragment" {
    grep -q 'SUDOERS_UPDATE=' "$INSTALL"
    grep -q 'gnss-update-agent' "$INSTALL"
    grep -q 'apply_update.sh /home/xeroth/base_station/staging/\*/base_station' "$INSTALL"
    grep -q 'visudo -cf' "$INSTALL"
}

@test "install.sh installs gnss-watchdog sudoers fragment with narrow scope" {
    grep -q 'SUDOERS_WATCHDOG=' "$INSTALL"
    # Must whitelist only `systemctl restart gnss-capture.service` — NOT
    # `systemctl <anything>` and NOT `bash <anything>`.
    grep -q 'systemctl restart gnss-capture.service' "$INSTALL"
    ! grep -qE 'NOPASSWD:[[:space:]]*ALL' "$INSTALL"
}

@test "install.sh adds OTA agent to crontab every 10 minutes" {
    grep -q 'gnss_update_agent.sh' "$INSTALL"
    grep -q '\*/10 \* \* \* \* \${DEST_SCRIPTS}/gnss_update_agent.sh' "$INSTALL"
}

@test "install.sh adds continuous-capture cron trio" {
    # All three must be present in the canonical cron block.
    grep -q '\* \* \* \* \* \${DEST_SCRIPTS}/gnss_upload_worker.sh' "$INSTALL"
    grep -q '\* \* \* \* \* \${DEST_SCRIPTS}/gnss-watchdog.sh' "$INSTALL"
    grep -q '\*/5 \* \* \* \* \${DEST_SCRIPTS}/gnss-disk-guard.sh' "$INSTALL"
}

@test "install.sh preserves existing STATION_ID when --station not given" {
    # The conditional: only require --station if station.conf is missing
    # or has no STATION_ID= line.
    grep -q 'if \[ ! -f "\${STATION_CONF}" \] || ! grep -qE' "$INSTALL"
}

@test "install.sh records installed version under state/version" {
    grep -q 'echo "\${VERSION}" > "\${DEST_STATE}/version"' "$INSTALL"
    grep -q 'installed v\${VERSION}' "$INSTALL"
}

@test "install.sh initialises state/channel without clobbering existing" {
    grep -q 'if \[ ! -f "\${DEST_STATE}/channel" \]' "$INSTALL"
    grep -qE 'DEFAULT_CHANNEL="?canary"?' "$INSTALL"
    grep -qE 'DEFAULT_CHANNEL="?stable"?' "$INSTALL"
}

@test "install.sh reads UPLOAD_KEY under set -euo pipefail, with and without a key" {
    # v1.2.0 stopped on XER2 at this step: no UPLOAD_KEY line, grep exit 1, pipefail.
    awk '/^conf_upload_key\(\)/,/^\}/' "$INSTALL" > "$BATS_TEST_TMPDIR/fn.sh"
    [ -s "$BATS_TEST_TMPDIR/fn.sh" ]
    printf 'STATION_ID=XER2\n4974523.9720 3008024.3060 -2616592.1730\n' > "$BATS_TEST_TMPDIR/nokey.conf"
    printf 'STATION_ID=XER7\nUPLOAD_KEY=xrx_abc_def\n' > "$BATS_TEST_TMPDIR/key.conf"
    run bash -c "set -euo pipefail; source '$BATS_TEST_TMPDIR/fn.sh'; k=\$(conf_upload_key '$BATS_TEST_TMPDIR/nokey.conf'); echo \"done[\$k]\""
    [ "$status" -eq 0 ]
    [ "$output" = "done[]" ]
    run bash -c "set -euo pipefail; source '$BATS_TEST_TMPDIR/fn.sh'; k=\$(conf_upload_key '$BATS_TEST_TMPDIR/key.conf'); echo \"done[\$k]\""
    [ "$output" = "done[xrx_abc_def]" ]
}
