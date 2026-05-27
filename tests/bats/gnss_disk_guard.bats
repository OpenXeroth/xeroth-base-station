#!/usr/bin/env bats
# =============================================================================
# gnss-disk-guard.sh — ring-buffer and protected-slot tests
#
# The disk guard is the sole defence against a long network outage filling
# the SD card. It must:
#   1. Descend into BOTH LOG_DIR/ and LOG_DIR/raw/ — the old maxdepth=1 form
#      never saw the raw UBX files and so was effectively a no-op (#37).
#   2. Protect the currently-writing slot (mtime within PROTECT_ACTIVE_AGE_S)
#      and the PROTECT_SLOTS newest closed slots. This preserves freshest
#      data at the cost of oldest — the opposite of a dumb FIFO delete.
#   3. Rotate its own log at MAX_LOG_BYTES with LOG_RETENTION=7 generations
#      so the disk guard's own log cannot contribute to disk exhaustion.
# =============================================================================

setup() {
    GUARD="${BATS_TEST_DIRNAME}/../../payload/hardening/gnss-disk-guard.sh"
    [ -x "$GUARD" ]
}

@test "gnss-disk-guard.sh scans both LOG_DIR and LOG_DIR/raw" {
    # The for-loop must iterate over both directories.
    grep -qE 'for d in "\$\{LOG_DIR\}" "\$\{RAW_DIR\}"' "$GUARD"
}

@test "gnss-disk-guard.sh uses maxdepth 1 per directory (no recursion escape)" {
    # Recursing deeper could sweep audit trees or user scratch. Keep it
    # to the two known data directories at depth 1.
    grep -q 'find "$d" -maxdepth 1 -type f' "$GUARD"
}

@test "gnss-disk-guard.sh protects the currently-writing slot" {
    grep -q 'PROTECT_ACTIVE_AGE_S' "$GUARD"
    # Files whose mtime is within PROTECT_ACTIVE_AGE_S seconds must be
    # filtered out BEFORE the purge candidate list is sorted.
    grep -q 'active_age < now' "$GUARD"
}

@test "gnss-disk-guard.sh protects the PROTECT_SLOTS newest candidates" {
    grep -q 'PROTECT_SLOTS' "$GUARD"
    # The purge budget is (total candidates - PROTECT_SLOTS).
    grep -q 'PURGE_COUNT=\$(( TOTAL_CANDIDATES - PROTECT_SLOTS ))' "$GUARD"
}

@test "gnss-disk-guard.sh aborts purge when only protected files remain" {
    grep -q 'PURGE_ABORT' "$GUARD"
    grep -q 'only ${TOTAL_CANDIDATES} candidates, PROTECT_SLOTS=${PROTECT_SLOTS}' "$GUARD"
}

@test "gnss-disk-guard.sh rotates its own log at MAX_LOG_BYTES with 7 generations" {
    grep -q 'MAX_LOG_BYTES=\${MAX_LOG_BYTES:-5242880}' "$GUARD"
    grep -q 'LOG_RETENTION=\${LOG_RETENTION:-7}' "$GUARD"
    # Rotation loop must cycle .1 .. .7 with the newest getting .1.
    grep -q 'for i in \$(seq \$((LOG_RETENTION - 1)) -1 1)' "$GUARD"
}

@test "gnss-disk-guard.sh considers all UBX/RINEX file extensions" {
    # The candidate set must include .ubx and its .tag sidecar plus the
    # RINEX products that might pile up if upload is failing.
    grep -q '\*.ubx' "$GUARD"
    grep -q '\*.ubx.tag' "$GUARD"
    grep -q '\*.obs' "$GUARD"
    grep -q '\*.nav' "$GUARD"
    grep -q '\*.rnx' "$GUARD"
}
