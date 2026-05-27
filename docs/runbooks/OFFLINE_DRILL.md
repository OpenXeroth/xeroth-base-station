# Runbook — Offline drill (station disconnection resilience)

## Purpose

Prove, on a real station, that a week-long network outage leaves the
capture pipeline continuous and that the backlog flushes to GCS when
the link returns. The ring-buffer disk guard and the upload worker
have been verified unit-by-unit; this runbook verifies them together.

Owner: field engineer with Tailscale access to the station.
Target for v1.0.0: **MY_STATION** (designated canary).
Prerequisite: `/health` reports `status=ok` at start.

## Preconditions to record before starting

Capture the following and paste them into the drill log as the baseline.
Do NOT start the drill if any of these look wrong.

```bash
# On the engineering laptop, against the target station:
TS_IP=$(tailscale ip -4 <station-host>)          # or MY_STATION, if drilling MY_STATION
BASE="http://${TS_IP}:8080"

curl -s "${BASE}/health" | tee /tmp/drill.baseline.health.json
ssh xeroth@"${TS_IP}" 'df -BM /home/xeroth/base_station/logs | tail -1'
ssh xeroth@"${TS_IP}" 'ls -1 /home/xeroth/base_station/logs/raw/ | tail -5'
ssh xeroth@"${TS_IP}" 'cat /home/xeroth/base_station/state/version'
```

Record: free space in MiB, newest rotation filename, current version.

## Procedure

### 1. Simulate outage

Pick ONE of the following to cut the station's upload path. Do not cut
Tailscale itself — we still need `/health` to diagnose what's happening.

- Revoke the GCS key: `sudo mv /home/xeroth/base_station/gnss-uploader-key.json{,.DRILL}`
- Block egress to `storage.googleapis.com` via iptables (leaves gcloud
  failing cleanly at TCP layer — matches flaky-network conditions).

The key-revoke form is reversible by a single `mv`. The iptables form
exercises the gcloud-timeout wrapper (#39) under stuck-TCP conditions.
Do one per drill, not both.

Record the wall-clock UTC time at the moment of cut.

### 2. Observe during outage (every 12 h for 7 d)

At each checkpoint, fetch `/health` and spot-check. The payload is
flat — top-level keys, not nested:

```bash
curl -s "${BASE}/health" | python3 -m json.tool
```

Pass conditions:

- `capture_service_active == true` — `str2str` is still up.
- `current_slot.present == true` and `current_slot.age_seconds < 20` —
  the live rotation file is being written right now (str2str writes
  every 0.2s-ish; a slot file going quiet for >20s is a stall).
- `upload_heartbeat.present == true` and `upload_heartbeat.age_seconds <
  120` — worker still ticking every cron minute, even with nothing to
  upload. During the outage the `state` field is expected to be
  `"idle"` or `"error"`, never absent.
- `raw_backlog.count` monotonically **increasing** — closed rotations
  are accumulating because uploads are blocked. That's the point of
  the drill.
- `disk.free_mb` monotonically decreasing at roughly the per-station UBX
  rate (~6–12 MiB per 10-minute slot, dual-freq, four constellations).
- `release.update_pending == false` — OTA agent sees no pending version
  change. If this flips to `true` during the drill you've released a new
  version mid-drill; restart the drill on a frozen channel.

Fail conditions (abort drill, record at the failure point):

- `/health` returns HTTP 503 for reasons other than upload auth/backlog
  (which are the expected symptoms of the cut). Inspect `reasons[]`:
  expected degrade reasons are `"no ACTIVE gcloud service account …"`,
  `"N closed raw UBX files awaiting processing"`, and
  `"N RINEX files awaiting upload retry in LOG_DIR"`. Anything else
  (`"gnss-capture.service is not active"`, `"current slot file stale"`,
  `"current slot file missing"`) is a **capture regression** — abort.
- `current_slot.age_seconds` exceeds 20 for two consecutive checkpoints
  — rotation has stalled under str2str.
- `disk.free_mb` falls below `2048` without `disk-guard.log` showing a
  `PURGED:` line since the previous checkpoint.

### 3. Observe ring-buffer engagement

Once `disk.free_mb` drops below 2048 MiB, the disk guard cron (every 5
min) MUST start purging oldest .ubx files. Check:

```bash
ssh xeroth@"${TS_IP}" 'tail -n 50 /home/xeroth/base_station/logs/disk-guard.log'
```

Expected lines: `LOW_DISK: ... starting purge`, then one or more `PURGED:`
entries, then a `PURGE_DONE: ... MB free (protected 3 newest + active
slot)`. The protected-slot count MUST remain >= 3 — verify by counting
the newest files still on disk after a purge pass:

```bash
ssh xeroth@"${TS_IP}" \
    'ls -lt /home/xeroth/base_station/logs/raw/*.ubx | head -4'
```

Four entries expected: the actively-written slot plus the three newest
closed slots.

### 4. Restore connectivity

Reverse whichever cut you made in step 1. Record the UTC time of restore.

### 5. Observe backfill

The upload worker runs every minute. It ingests the raw/ directory oldest-
first and also sweeps `.obs`/`.nav` left over from prior runs. Expected
backfill velocity is limited by upload bandwidth, not by the worker —
the script processes as many slots per minute as it can convert+upload
within the cron interval.

Check progress every 15 min until backlog clears:

```bash
ssh xeroth@"${TS_IP}" 'ls /home/xeroth/base_station/logs/raw/*.ubx | wc -l'
ssh xeroth@"${TS_IP}" 'tail -n 30 /home/xeroth/base_station/logs/automation.log'
```

Pass condition: raw/ file count monotonically decreases over consecutive
checkpoints. Every processed slot produces two `Uploaded ...` lines in
automation.log (one .obs, one .nav). No `ERROR:` lines for files that
are still on disk.

### 6. Post-drill verification

Once raw/ count reaches the steady state (1–2 files: the currently-writing
slot and possibly the most recent closed slot awaiting its next worker
tick):

```bash
# GCS-side: count .obs landed in the drill window (use your drill UTC
# cut/restore timestamps).
gcloud storage ls gs://xeroth-base-stations-data/MY_STATION/2026/$(date -u -d '7 days ago' +%j)/*.obs | wc -l
gcloud storage ls gs://xeroth-base-stations-data/MY_STATION/2026/$(date -u +%j)/*.obs | wc -l
```

Compare against expected count: (drill duration minutes / 10). Accept
loss on the oldest end equal to whatever the disk guard purged —
record the exact purged count from `disk-guard.log`. Anything beyond
that is a bug.

## Expected outcome

- Capture continuous, no gaps in the RINEX observation stream in GCS
  other than the exact minutes covered by disk-guard purges.
- /health never goes non-200 during the drill.
- Backfill completes within 1–2 hours of connectivity restore for a
  7-day outage (network-speed dependent).

## Failure modes to watch for

| Symptom                                               | Likely cause                                    | Mitigation                                                     |
|-------------------------------------------------------|-------------------------------------------------|----------------------------------------------------------------|
| `upload.heartbeat_age_seconds` > 300                  | Upload worker stuck on gcloud TCP               | Verify `GCLOUD_TIMEOUT_S=45` (#39) — should auto-recover       |
| Disk fills past MIN_FREE_MB without PURGED lines      | disk-guard cron not firing, or log-partition mismatch | Check `sudo -u xeroth crontab -l \| grep disk-guard`           |
| raw/ file count grows after connectivity restore      | convbin or gcloud failing silently              | Check `automation.log` for ERROR lines; check `${GCS_KEY}` permissions |
| `/health` returns `capture.status=stalled`            | str2str died, watchdog not restarting           | Check `systemctl status gnss-capture.service`; sudoers fragment installed |
| Ring-buffer drops a freshly-closed slot               | PROTECT_SLOTS miscount                          | **Regression.** Abort drill, re-run the disk-guard bats tests  |

## Drill log template

Paste a completed form into the drill's PR or incident record:

```
Station:           XER{1,2}
Drill start (UTC):
Drill cut method:  (key-revoke | iptables)
Drill end (UTC):
Baseline:
  free_mb:
  newest rotation:
  version:
Mid-drill peak:
  raw/ file count:
  disk free_mb low-water:
  PURGED count:
  /health non-200 events:
Backfill complete at (UTC):
Total .obs in GCS over window:
Expected .obs over window:
Delta vs. PURGED count:          (must be 0 — one bug per slot otherwise)
Notes:
```
