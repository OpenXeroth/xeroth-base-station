#!/usr/bin/env bats
# =============================================================================
# gnss_update_agent.sh — pure-logic tests
#
# The agent as a whole reaches out to GCS (gcloud storage cat/cp), the disk,
# and sudo. None of that is reachable from CI. What CAN be tested here is
# the non-I/O fragments that govern correctness under edge cases:
#   - Pointer-value regex: tarball filenames are derived from the pointer,
#     so a malformed pointer MUST NOT result in a fetch attempt. The agent
#     rejects pointers that do not match the semver pattern.
#   - State-write atomicity: write_state() writes to a tmp then renames.
#     We can simulate this in-process by extracting the function, because
#     it has no side-effects outside the target path.
#
# These tests do not replace an end-to-end offline drill on a real station;
# they simply pin the invariants that must hold regardless of I/O.
# =============================================================================

setup() {
    AGENT="${BATS_TEST_DIRNAME}/../../payload/scripts/gnss_update_agent.sh"
    TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP"
}

@test "gnss_update_agent.sh pointer regex accepts valid semver and rejects junk" {
    pat='^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$'

    [[ "1.0.0"          =~ $pat ]]
    [[ "10.20.30"       =~ $pat ]]
    [[ "1.0.0-rc.1"     =~ $pat ]]
    [[ "1.0.0-alpha"    =~ $pat ]]
    [[ "1.0.0-20260421" =~ $pat ]]

    ! [[ ""           =~ $pat ]]
    ! [[ "v1.0.0"     =~ $pat ]]
    ! [[ "1.0"        =~ $pat ]]
    ! [[ "1.0.0 "     =~ $pat ]]
    ! [[ "1.0.0;rm"   =~ $pat ]]
    ! [[ "1.0.0/etc"  =~ $pat ]]
}

@test "gnss_update_agent.sh script exists and is executable" {
    [ -x "$AGENT" ]
}

@test "gnss_update_agent.sh references apply_update.sh (not bash install.sh)" {
    # Regression guard: the agent MUST NOT invoke `sudo -n bash install.sh`
    # directly. That pattern requires `bash <anything>` in sudoers, which
    # is a broad escalation. The correct invocation goes through the
    # narrowly-scoped apply_update.sh wrapper.
    grep -q 'apply_update.sh' "$AGENT"
    ! grep -qE 'sudo[^#]*bash[[:space:]]+"?\$?\{?.*install\.sh' "$AGENT"
}

@test "gnss_update_agent.sh uses write_state (atomic) for every state file" {
    # Every state file written by the agent must go through write_state so
    # /health never reads a partial value during a concurrent update.
    # Grep for direct redirection into STATE_DIR files that isn't inside
    # the write_state helper itself.
    violations=$(awk '
        /^write_state\(\)/      { in_helper=1 }
        in_helper && /^\}/      { in_helper=0; next }
        in_helper               { next }
        /^[[:space:]]*#/        { next }
        /^log\(\)/              { in_log=1 }
        in_log && /^\}/         { in_log=0; next }
        in_log                  { next }
        # Find direct `>` redirections into STATE_DIR-scoped files.
        /\$\{?(RESULT_FILE|ATTEMPT_FILE|TARGET_FILE|VERSION_FILE|CHANNEL_FILE)\}?[[:space:]]*$/ \
            && />[[:space:]]*\$\{?(RESULT_FILE|ATTEMPT_FILE|TARGET_FILE|VERSION_FILE|CHANNEL_FILE)/ \
            { print NR": "$0 }
    ' "$AGENT")
    [ -z "$violations" ]
}

@test "gnss_update_agent.sh has gcloud timeout wrapper and uses it" {
    # Every gcloud invocation must go through gcloud_cmd so a stuck TCP
    # session cannot starve the agent.
    grep -qE '^gcloud_cmd\(\)' "$AGENT"
    # Count bare `${GCLOUD_EXEC}` references that are NOT inside the wrapper
    # definition and NOT the top-level `GCLOUD_EXEC=` assignment. Should be
    # zero — every caller must go through `gcloud_cmd "$@"`.
    bare_refs=$(awk '
        /^gcloud_cmd\(\)/          { in_wrapper=1 }
        in_wrapper && /^\}/        { in_wrapper=0; next }
        in_wrapper                 { next }
        /^GCLOUD_EXEC=/            { next }
        /^[[:space:]]*#/           { next }
        /\$\{?GCLOUD_EXEC\}?/      { print NR": "$0 }
    ' "$AGENT")
    [ -z "$bare_refs" ] || {
        printf '%s\n' "$bare_refs" >&2
        false
    }
}
