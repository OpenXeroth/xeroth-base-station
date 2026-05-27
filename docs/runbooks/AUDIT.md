# Runbook — Non-destructive station audit

Confirm that a station is actually delivering the contract it
advertises:

1. **Continuous dual-frequency capture** — `str2str` has not dropped
   since the last known-good start, rotations land on UTC 10-minute
   boundaries, and the recorded UBX contains L1 + L2/L5 observations
   for all enabled constellations.
2. **Uploads land in GCS** — every closed rotation converts to RINEX
   3.03 (`.obs` + `.nav`) and reaches `gs://xeroth-base-stations-data/${STATION_ID}/…`
   with no durable backlog on disk.
3. **Offline resilience primitives are engaged** — the ring-buffer
   disk guard is running, the upload worker retries cleanly, the
   gcloud timeout wrapper is in place.
4. **OTA state is consistent** — `release.version`, `release.channel`,
   and `release.update_pending` reflect reality, and the
   `gnss_update_agent.sh` cron has ticked recently.

This is a **non-destructive** audit. No `sudo` commands. For the
destructive end-to-end "7-day outage" drill, see `OFFLINE_DRILL.md`.

## Prerequisites

- Tailscale connectivity to the station and SSH as `xeroth`.
- `gcloud` authenticated against the GCP project with read access
  to `gs://xeroth-base-stations-data`.

## Set up the audit session

```bash
STATION=<your-station-id>            # e.g. MY_STATION
STATION_HOST=<station-tailscale-hostname-or-ip>

TS_IP=$(ssh xeroth@${STATION_HOST} 'tailscale ip -4')
BASE="http://${TS_IP}:8080"
AUDIT_DIR="$HOME/audit-${STATION}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${AUDIT_DIR}"
cd "${AUDIT_DIR}"
```

Every diagnostic below writes evidence into `${AUDIT_DIR}` so the
audit is reproducible.

## 1. Snapshot `/health`

```bash
curl -sS "${BASE}/health" > health.json
python3 -m json.tool < health.json | tee health.pretty.json
```

Expect:
- `status: "ok"` (HTTP 200). If `status: "degraded"`, the `reasons`
  array enumerates every condition that tripped. Treat each as a
  finding.
- `capture_service_active: true`.
- `current_slot.present: true` and `current_slot.age_seconds` < 30.
  An age larger than 30 s means str2str has not written in the last
  capture interval — the watchdog should restart it within ~60 s.
- `upload_heartbeat.age_seconds` < 300.
- `raw_backlog.count <= 3` and `rinex_backlog_count == 0`.
- `gcs_auth_active: true`.
- `disk.free_mb` > 2048.
- `release.version` matches the channel target — i.e.
  `release.target_version == release.version` and
  `release.last_update_result == "up_to_date"`.

## 2. Confirm capture cadence on the box

```bash
ssh xeroth@${STATION_HOST} 'systemctl status gnss-capture.service --no-pager' > capture.status
grep -E "Active|Main PID|str2str" capture.status

ssh xeroth@${STATION_HOST} 'ls -la /home/xeroth/base_station/logs/raw/ | head -20' > raw_ls.txt
cat raw_ls.txt

ssh xeroth@${STATION_HOST} 'date -u +%Y-%m-%dT%H:%M:%SZ; \
    stat -c "%y %s %n" /home/xeroth/base_station/logs/raw/*.ubx | sort' > raw_stat.txt
tail -20 raw_stat.txt
```

Expect:
- `systemctl status` shows `Active: active (running)` with no recent
  restarts.
- `ls raw/` shows at most a handful of `.ubx` files — the current
  slot growing, possibly a couple of closed slots waiting for
  upload, no older files.
- The newest `.ubx` file has mtime within the last few seconds and
  size growing between checks.

## 3. Verify uploads landed in GCS

```bash
YEAR=$(date -u +%Y)
DOY=$(date -u +%j)
PREV_DOY=$(date -u -d '1 day ago' +%j)

# Today's slots:
gcloud storage ls -l \
    gs://xeroth-base-stations-data/${STATION}/${YEAR}/${DOY}/ > gcs_today.txt
wc -l gcs_today.txt

# Yesterday's slots:
gcloud storage ls -l \
    gs://xeroth-base-stations-data/${STATION}/${YEAR}/${PREV_DOY}/ > gcs_yesterday.txt
wc -l gcs_yesterday.txt
```

Expect:
- The most recent closed slot is present in GCS within ~2 minutes of
  the slot ending (slots end on UTC :00/:10/:20/:30/:40/:50; allow
  for the next upload-worker tick + convbin + upload).
- For a fully captured day, expect 6 slots/hour × 24 hours × 2 files
  (.obs + .nav) = 288 files.
- No gaps inside an operational day. Gaps that align to known
  outage windows are expected; gaps that do not are findings.

## 4. Inspect the upload-worker log

```bash
ssh xeroth@${STATION_HOST} 'tail -n 200 /home/xeroth/base_station/logs/automation.log' > automation.tail
grep -E "Uploaded|Slot.*complete|ERROR|TIMEOUT" automation.tail | tail -30
```

Expect:
- A steady cadence of `Uploaded` and `Slot N complete` lines, one
  pair per closed slot.
- No `ERROR:` lines in the recent tail.
- `TIMEOUT:` lines are not failures themselves — they indicate the
  gcloud timeout wrapper kicked in, the file stayed on disk, and
  the next worker tick will retry. A small number is normal under
  flaky links; a sustained run is a finding.

## 5. Confirm OTA state

```bash
ssh xeroth@${STATION_HOST} 'cat /home/xeroth/base_station/state/version' > version.txt
ssh xeroth@${STATION_HOST} 'cat /home/xeroth/base_station/state/channel' > channel.txt
ssh xeroth@${STATION_HOST} 'cat /home/xeroth/base_station/state/target_version 2>/dev/null' > target.txt
ssh xeroth@${STATION_HOST} 'tail -n 30 /home/xeroth/base_station/state/updates.log' > updates.tail
cat version.txt channel.txt target.txt
echo "---"
cat updates.tail
```

Expect:
- `version.txt` and `target.txt` are identical (station is at the
  channel target).
- `channel.txt` is either `stable` or `canary`.
- `updates.tail` shows a recent successful poll. If every recent
  line is `UPDATE_CHECK:` followed by `up_to_date`, that's normal.
  Lines `POLL_FAILED:` indicate transient network issues; a
  sustained run is a finding.

## 6. Dual-frequency verification (optional)

Spot-check that the receiver is recording multi-frequency
observations, not L1 only:

```bash
# Fetch a recent .obs file:
RECENT_OBS=$(gcloud storage ls gs://xeroth-base-stations-data/${STATION}/${YEAR}/${DOY}/*.obs \
    | tail -1)
gcloud storage cp "${RECENT_OBS}" /tmp/recent.obs

# Look at the SYS / # / OBS TYPES header — should list L1 + L2 (GPS)
# and L1 + E5b (Galileo) at minimum:
grep "SYS / # / OBS TYPES" /tmp/recent.obs | head -10
```

If only L1-band observables appear for any constellation, the
receiver dropped a band. Run `ensure_receiver.py` on the station
to re-apply the CFG-VALSET that enables RAWX on all bands.

## Reporting

Write a one-page summary in `${AUDIT_DIR}/SUMMARY.md`:

```markdown
# Audit summary — ${STATION} — ${DATE_UTC}

- `/health`:                 ok | degraded — <reasons>
- Capture service:           active | inactive
- Latest slot in GCS:        <YYYYMMDDhhmm> (<age> ago)
- Slots in last 24h:         <N> of 288 expected
- Upload backlog:            <count>
- ERRORs in automation log:  <count>
- Release version:           <X.Y.Z>, channel=<chan>, up_to_date=<bool>
- Dual-frequency:            confirmed | only-L1 | not-checked

Findings:
1. ...
2. ...

Recommendations:
1. ...
```

Attach the contents of `${AUDIT_DIR}` to the issue or PR that closes
out the audit.
