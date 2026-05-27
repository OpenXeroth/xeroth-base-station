#!/usr/bin/env bats
# =============================================================================
# gnss_upload_worker.sh — pure-logic tests
#
# End-to-end exercises require gcloud credentials and a receiver producing
# UBX. These tests pin only the script-local invariants:
#   - The worker never re-converts a file that already has RINEX on disk
#     (idempotency under long outages).
#   - filename_to_gcs_prefix reverse-parses YYYYMMDDHHMM and emits the
#     correct GCS path fragment.
#   - The worker tolerates a deleted .tag sidecar without re-processing
#     the matching .ubx.
# =============================================================================

setup() {
    WORKER="${BATS_TEST_DIRNAME}/../../payload/scripts/gnss_upload_worker.sh"
    [ -x "$WORKER" ]
    TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP"
}

@test "gnss_upload_worker.sh defines ensure_rinex that short-circuits on existing RINEX" {
    # Regression guard against #38 (long-outage wasteful re-conversion).
    grep -q 'ensure_rinex()' "$WORKER"
    # The short-circuit is: if both .obs and .nav exist and non-empty, return 0
    # without running convbin.
    awk '/^ensure_rinex\(\)/,/^\}/' "$WORKER" \
        | grep -q 'if \[ -s "${rinex_obs}" \] && \[ -s "${rinex_nav}" \]; then'
    awk '/^ensure_rinex\(\)/,/^\}/' "$WORKER" \
        | grep -q 'return 0'
}

@test "gnss_upload_worker.sh uses gcloud_cmd timeout wrapper" {
    # Regression guard against #39 (unbounded gcloud hang).
    grep -qE '^gcloud_cmd\(\)' "$WORKER"
    # Every gcloud invocation must go through the wrapper, not direct.
    awk '
        /^gcloud_cmd\(\)/,/^\}/   { next }
        /^[[:space:]]*#/           { next }
        /GCLOUD_EXEC=/             { next }
        /\$\{?GCLOUD_EXEC\}?/      { print NR": "$0 }
    ' "$WORKER" > "$TMP/bare_gcloud_refs.txt"
    # Expected bare references: exactly zero. The wrapper itself is excluded
    # by the first range pattern.
    [ ! -s "$TMP/bare_gcloud_refs.txt" ] || {
        cat "$TMP/bare_gcloud_refs.txt" >&2
        false
    }
}

@test "gnss_upload_worker.sh skips files newer than MIN_CLOSED_AGE (live-file guard)" {
    grep -q 'MIN_CLOSED_AGE=60' "$WORKER"
    # The worker must compare mtime vs NOW_EPOCH - MIN_CLOSED_AGE before
    # processing any .ubx file, else it will race str2str.
    grep -q 'age=\$(( NOW_EPOCH - mtime ))' "$WORKER"
    grep -q 'if \[ "\${age}" -lt "\${MIN_CLOSED_AGE}" \]' "$WORKER"
}

@test "gnss_upload_worker.sh writes a heartbeat every run, not only on work" {
    # The /health endpoint's STALE_UPLOAD_HB_S threshold fires if no
    # heartbeat is written within the worker's cron interval. Idle minutes
    # must still write a heartbeat.
    # The last `heartbeat "idle"` must appear AFTER the raw/*.ubx processing
    # loop (i.e. run unconditionally at script end).
    last_hb_line=$(grep -n 'heartbeat "idle"' "$WORKER" | tail -n 1 | cut -d: -f1)
    last_ubx_loop_line=$(grep -n '^for ubx in' "$WORKER" | tail -n 1 | cut -d: -f1)
    [ -n "$last_hb_line" ]
    [ -n "$last_ubx_loop_line" ]
    [ "$last_hb_line" -gt "$last_ubx_loop_line" ]
}

@test "gnss_upload_worker.sh filename_to_gcs_prefix parses YYYYMMDDHHMM" {
    # Extract the function and exercise it in a subshell with stubs.
    # STATION_ID is set to TEST; GCP_BUCKET overrides to gs://test.
    cat > "$TMP/stubs.sh" <<'EOF'
GCP_BUCKET="gs://test"
STATION_ID="TEST"
DATE_EXEC=/usr/bin/date
EOF
    sed -n '/^filename_to_gcs_prefix()/,/^}$/p' "$WORKER" > "$TMP/func.sh"
    (
        # shellcheck disable=SC1090
        source "$TMP/stubs.sh"
        # shellcheck disable=SC1090
        source "$TMP/func.sh"
        out=$(filename_to_gcs_prefix "/tmp/202603150730.obs")
        [ "$out" = "gs://test/TEST/2026/074" ]
    )
}

@test "gnss_upload_worker.sh tag-sidecar sweep has liveness guard" {
    # Sidecar sweep must skip tags whose mtime is within MIN_CLOSED_AGE;
    # otherwise a tag written by a still-active rotation could be deleted.
    grep -q 'NOW_EPOCH - tag_mtime' "$WORKER"
    grep -qE -- '-ge "\$\{MIN_CLOSED_AGE\}"' "$WORKER"
}
