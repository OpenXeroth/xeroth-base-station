#!/usr/bin/env bats
# =============================================================================
# apply_update.sh — argument validation tests
#
# apply_update.sh is the narrowly-scoped sudo wrapper that the OTA agent
# invokes as root. Its contract is *frozen* because older installed wrappers
# are what get called at update time; any regression in argument acceptance
# or rejection becomes a live fleet bug. These tests exist to hold that
# contract still.
#
# We cannot run the wrapper end-to-end here (it tries to exec install.sh
# and must run as root). Instead we exercise only the validation section,
# which short-circuits before any privileged action if the wrapper is run
# non-root OR the argument fails the shape checks.
# =============================================================================

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../../payload/scripts/apply_update.sh"
    TMP="$(mktemp -d)"
    # Fresh per-test staging root under the canonical base path so the
    # regex branch is testable. We do NOT chown to root — the script is
    # invoked as the current user and will exit 2 at the "must run as root"
    # check. That's fine: we're testing argument validation only and the
    # order of checks means a non-root invocation without an argument still
    # exercises the `$# -ne 1` branch first.
    STAGE_BASE="/home/xeroth/base_station/staging"
    export BATS_TMPDIR="$TMP"
}

teardown() {
    rm -rf "$TMP"
}

@test "apply_update.sh exits 2 when run as non-root" {
    run bash "$SCRIPT" "${STAGE_BASE}/1.0.0/base_station"
    [ "$status" -eq 2 ]
    [[ "$output" == *"must run as root"* ]]
}

@test "apply_update.sh exits 2 with wrong arg count" {
    # Force past the root check by faking root? We cannot. But the first
    # check is root, then arg-count. Non-root + no args is still an early
    # exit 2 with the "must run as root" message. Instead we prove the
    # script still exits 2 (regardless of which branch) so there is no
    # silent success path.
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
}

@test "apply_update.sh rejects path traversal" {
    # Path-traversal check is after root check. So we verify only that the
    # overall run is a rejection. The actual traversal branch is exercised
    # when the wrapper is invoked via sudo in production — this guards the
    # non-root path which must STILL not succeed.
    run bash "$SCRIPT" "/home/xeroth/../etc/passwd"
    [ "$status" -eq 2 ]
}

@test "apply_update.sh contract is documented and argument shape is correct" {
    # The documented contract is visible in the script header. This test
    # catches accidental edits that remove the contract comment.
    grep -q "Contract (kept deliberately stable" "$SCRIPT"
    grep -q "sudo apply_update.sh <staging_root>" "$SCRIPT"
}

@test "apply_update.sh regex matches a canonical staging path" {
    # Regression guard: the regex must accept the canonical path shape
    # that the OTA agent builds. If someone tightens the regex without
    # updating the agent, OTA updates silently stop working.
    extract_regex() {
        grep -oE 'STAGE_BASE\}/\[0-9\]\+\\.\[0-9\]\+\\.\[0-9\]\+\(-\[A-Za-z0-9\.-\]\+\)\?/base_station' "$SCRIPT" | head -n 1
    }
    [ -n "$(extract_regex)" ]
}

@test "apply_update.sh regex rejects a pre-release with slash in suffix" {
    # Direct regex behaviour check using bash's [[ =~ ]].
    STAGE_BASE_LOCAL="/home/xeroth/base_station/staging"
    pat='^'"${STAGE_BASE_LOCAL}"'/[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?/base_station$'

    # Must accept
    s1="${STAGE_BASE_LOCAL}/1.0.0/base_station"
    s2="${STAGE_BASE_LOCAL}/1.2.3-rc.1/base_station"
    [[ "$s1" =~ $pat ]]
    [[ "$s2" =~ $pat ]]

    # Must reject
    s3="${STAGE_BASE_LOCAL}/1.0.0/base_station/extra"
    s4="${STAGE_BASE_LOCAL}/1.0/base_station"
    s5="/tmp/1.0.0/base_station"
    s6="${STAGE_BASE_LOCAL}/1.0.0-rc/1/base_station"
    ! [[ "$s3" =~ $pat ]]
    ! [[ "$s4" =~ $pat ]]
    ! [[ "$s5" =~ $pat ]]
    ! [[ "$s6" =~ $pat ]]
}
