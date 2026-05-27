# snareSAR base station operations

## Architecture (continuous-capture, 2026-04-21 onward)

Capture is continuous. There is no cycle. `gnss-capture.service` runs
`str2str` as a resident process, holding the FTDI serial port (ttyUSB0)
exclusively and writing UBX bytes into
`/home/xeroth/base_station/logs/raw/%Y%m%d%h%M.ubx`. The file rotates on
every 10-minute UTC boundary (:00, :10, :20, :30, :40, :50) via RTKLIB's
`::S=0.16667` swap interval. `-f 30` pre-opens the next file 30 s before
the boundary; at the boundary the write switches atomically.

Result: each `YYYYMMDDHHMM.ubx` file covers the 10-minute slot whose
start is encoded in its name, plus a 30-second overlap with the previous
slot at its leading edge. No bytes are lost at the seam — `str2str`
writes to both files during the margin, so every receiver second is
present in at least one file.

The upload-half runs from cron every minute as `gnss_upload_worker.sh`.
It walks `logs/raw/`, ignores any file whose mtime is newer than 60 s
(the currently-writing slot), and for each closed `.ubx`:

1. `convbin -v 3.03 -r ubx -f 2` produces dual-frequency RINEX 3.03
   `.obs` and `.nav`.
2. The `APPROX POSITION XYZ` line in `.obs` is replaced with the
   AUSPOS-surveyed ITRF2020 coordinate from `station.conf`.
3. Both files upload to
   `gs://xeroth-base-stations-data/<STATION>/YYYY/DOY/YYYYMMDDHHMM.{obs,nav}` via
   `gcloud storage cp`, each verified with `gcloud storage ls`.
4. On verified success, the raw `.ubx`, its RTKLIB `.ubx.tag` sidecar,
   and the local `.obs`/`.nav` are deleted. On failure the raw `.ubx`
   stays and the next worker run retries.

The worker writes `/home/xeroth/base_station/state/upload.heartbeat` on
every invocation, so the health endpoint can observe that the worker
is running even during minutes when there is no closed slot to process.

Three systemd units and two cron entries define the station's
steady state:

| Unit / job                   | Role                                                        |
|------------------------------|-------------------------------------------------------------|
| `gnss-receiver.service`      | Oneshot. `ExecStart=ensure_receiver.py` re-applies UBX CFG-VALSET at boot (and on capture restart via `ExecStartPre`). |
| `gnss-capture.service`       | Long-running `str2str` — continuous UBX capture with 10-min rotation. |
| `gnss-health.service`        | Tailscale-only HTTP `/health` endpoint on port 8080.        |
| cron: `gnss_upload_worker.sh`| Every minute. Converts + uploads closed UBX rotations.      |
| cron: `gnss-watchdog.sh`     | Every minute. Restarts capture if the current raw file mtime goes stale. |
| cron: `gnss-disk-guard.sh`   | Every 5 minutes. Rotates internal logs, prunes orphan UBX on low disk. |

The watchdog holds `/etc/sudoers.d/gnss-watchdog` permission to restart
`gnss-capture.service` — nothing else. It never touches cron.

## Health at a glance

Each station exposes `GET http://<tailscale-ip>:8080/health` on port 8080
(bound only to the 100.64.0.0/10 Tailscale CGNAT address — never WAN).
HTTP 200 when `status == "ok"`, 503 when `status == "degraded"`. Use
`curl --fail` for an exit-code probe.

Response shape (see `gnss_health.py` for the full schema):

```
{
  "status": "ok",                                   # or "degraded"
  "station_id": "MY_STATION",
  "server_time_iso": "2026-04-21T15:53:57Z",
  "capture_service_active": true,
  "current_slot": {
    "slot": "202604211550",                    # actual filename stem str2str is writing to
    "canonical_slot": "202604211550",          # id of current 10-min UTC boundary window
    "path": "/home/xeroth/base_station/logs/raw/202604211550.ubx",
    "present": true, "size": 921740,
    "mtime_epoch": 1776786837, "mtime_iso": "2026-04-21T15:53:57Z",
    "age_seconds": 0
  },
  "upload_heartbeat": {
    "present": true, "state": "idle",
    "epoch": 1776786782, "iso": "2026-04-21T15:53:02Z",
    "age_seconds": 55
  },
  "last_upload":        { "epoch": ..., "file": "202604211540.nav", ... },
  "last_slot_complete": { "epoch": ..., "slot": "202604211540", ... },
  "last_error":         { "epoch": ..., "message": "ERROR: ..." } | null,
  "raw_backlog":        { "count": 0, "oldest": null },
  "rinex_backlog_count": 0,
  "gcs_auth_active": true,
  "disk":     { "free_mb": 47561, "total_mb": 58808, "percent_used": 19.1, ... },
  "baud_conf": 115200,
  "load_avg": { "1m": 0.07, "5m": 0.07, "15m": 0.02 },
  "uptime":   { "seconds": 123456 },
  "reasons":  []                                    # why status != "ok"
}
```

Authoritative freshness signals (in priority order):

**Why both `slot` and `canonical_slot`?** `str2str` names each rotation
file by the current minute at file-open time (`%Y%m%d%h%M.ubx`), not by
the 10-minute UTC boundary. The two only coincide when `str2str` happens
to start on a boundary. `slot` reports the actual filename stem (so you
can locate the file on disk); `canonical_slot` reports the id of the
current 10-minute window (so you can correlate with upload/backlog logs
which use the same scheme). They will disagree for a few minutes after
any `gnss-capture.service` restart, then converge at the next boundary.
The watchdog does not use either — it looks at the newest `.ubx` mtime.

| Signal                    | Source                                                                  | Threshold |
|---------------------------|-------------------------------------------------------------------------|-----------|
| `capture_service_active`  | `systemctl is-active gnss-capture.service`                              | must be `true` |
| `current_slot.age_seconds`| mtime of the newest `.ubx` in `raw/` (whichever str2str is writing)      | `> 30 s` → stale |
| `upload_heartbeat.age_seconds` | mtime/content of `state/upload.heartbeat`                          | `> 300 s` → stale |
| `raw_backlog.count`       | closed `*.ubx` in `logs/raw/` (not current slot)                        | `> 3` → backlog |
| `rinex_backlog_count`     | `*.obs`/`*.nav`/`*.rnx` in `logs/`                                      | `> 3` → upload failing |
| `gcs_auth_active`         | `gcloud auth list --filter=status:ACTIVE`                               | must be `true` |
| `disk.free_mb`            | `statvfs(logs/)`                                                         | `< 2048` → low disk |

Status degrades (HTTP 503, `reasons` populated) when any threshold trips.

Quick checks from any Tailscale peer:

```
curl -s http://<STATION_TAILSCALE_IP>:8080/health | python3 -m json.tool    # MY_STATION
curl -s http://<STATION_TAILSCALE_IP>:8080/health | python3 -m json.tool    # MY_STATION
curl --fail -sS http://<STATION_TAILSCALE_IP>:8080/health > /dev/null && echo OK
```

## Zero-gap continuity

`str2str`'s `-f 30` margin makes every rotation an atomic switch with
overlap. There is no gap at a rotation boundary — consecutive files
share 30+ seconds of UBX at the seam, and the RINEX output reflects
this:

```
# 202604211538.obs (file N, seed file after service start)
TIME OF FIRST OBS: 2026-04-21 15:38:57.988 GPS
TIME OF LAST OBS:  2026-04-21 15:40:19.988 GPS

# 202604211540.obs (file N+1, crosses 15:40:00 boundary)
TIME OF FIRST OBS: 2026-04-21 15:39:34.988 GPS
TIME OF LAST OBS:  2026-04-21 15:50:33.987 GPS

# 202604211550.obs (file N+2, crosses 15:50:00 boundary)
TIME OF FIRST OBS: 2026-04-21 15:49:34.987 GPS
```

Boundary N→N+1 overlap = `15:39:34.988 ... 15:40:19.988` = 45.0 s.
Boundary N+1→N+2 overlap = `15:49:34.987 ... 15:50:33.987` = 59.0 s.

Post-processors see continuous observations; de-duplication on the PPK
side is idempotent because each epoch is timestamped identically in
both files.

## Operator controls

Stop capture temporarily (e.g. for maintenance on the FTDI):

```
sudo systemctl stop gnss-capture.service     # str2str exits, port freed
# upload worker will keep processing any closed slots still on disk
# resume with:
sudo systemctl start gnss-capture.service
```

Disable the upload path without touching capture (e.g. to drain backlog
locally):

```
sudo -u xeroth crontab -r
# restore with:
sudo -u xeroth crontab /tmp/saved-crontab   # or re-run install.sh
```

Force the worker to run now (without waiting for the next minute tick):

```
sudo -u xeroth /home/xeroth/base_station/scripts/gnss_upload_worker.sh
```

Inspect the live UBX stream (only possible while `gnss-capture.service`
is stopped — `str2str` holds the port exclusively):

```
sudo systemctl stop gnss-capture.service
python3 /home/xeroth/base_station/scripts/ensure_receiver.py    # prints baud or 'FAILED'
sudo systemctl start gnss-capture.service
```

Re-run the full install to refresh scripts / systemd units / cron:

```
cd /path/to/snaresar/base_station
sudo ./install.sh --station MY_STATION
```

## Watching logs

```
tail -F /home/xeroth/base_station/logs/automation.log        # upload worker
tail -F /home/xeroth/base_station/logs/watchdog.log          # watchdog
sudo journalctl -u gnss-capture.service -f                   # str2str stream
sudo journalctl -u gnss-health.service -f                    # health endpoint
sudo journalctl -u gnss-receiver.service -f                  # boot-time recv cfg
ls -la /home/xeroth/base_station/logs/raw/                   # current slot + any backlog
```

## Data contract for PPK

- Bucket: `gs://xeroth-base-stations-data/`
- Prefix: `<STATION_ID>/<YYYY>/<DOY>/`
- Filenames: `YYYYMMDDHHMM.obs` and `YYYYMMDDHHMM.nav` (RINEX 3.03,
  `-f 2` → dual-frequency observables: C1C/L1C + C2X/L2X on GPS,
  C1C/L1C + C2C/L2C on GLONASS, C1X/L1X + C7X/L7X on Galileo,
  C2I/L2I + C7I/L7I on BeiDou).
- Coverage: one 10-minute file per slot, continuous across rotations
  with ≥ 30 s overlap at each seam.
- `APPROX POSITION XYZ` in the `.obs` header is the ITRF2020 antenna
  ARP from `station.conf` (AUSPOS-surveyed).
- Latency: ≤ 2 minutes from slot close to file appearing in GCS
  (worker runs every minute; processing is convbin + upload + verify).

## Troubleshooting

| Symptom / `reasons[]` entry                                              | First check                                                                                                   |
|--------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------|
| Station offline in Tailscale                                             | Power / WiFi. Station has no route without Tailscale.                                                         |
| `curl` to `/health` hangs or connection-refused                          | `sudo systemctl status gnss-health.service`. Check `journalctl -u gnss-health.service`.                       |
| `gnss-capture.service is not active`                                     | `sudo systemctl status gnss-capture.service`. `journalctl -u gnss-capture.service --since "10 min ago"`.      |
| `current slot file missing` or `mtime > 30s`                             | str2str alive but stream stalled — FTDI/receiver hang. Watchdog restarts within 1 min; investigate if chronic.|
| `stale upload heartbeat`                                                  | Upload worker not running. Check `sudo -u xeroth crontab -l` and `/var/log/syslog` for cron errors.           |
| `raw_backlog > 3`                                                         | Worker is running but failing to process. Read `tail -200 automation.log` for the specific convbin/upload error. |
| `rinex_backlog > 3`                                                       | convbin succeeded but uploads failing. Check `gcloud auth list` and network. Files in `logs/` will retry.     |
| `gcs_auth_active is false`                                                | `sudo -u xeroth gcloud auth list`. Re-activate via `gcloud auth activate-service-account --key-file ~/base_station/gnss-uploader-key.json`. |
| `disk free < 2048 MB`                                                     | `df -h /home/xeroth`. `gnss-disk-guard.sh` should prune — check `/var/log/xeroth-disk-guard.log`.             |
| `convbin` runs but only produces L1 RINEX                                 | Confirm `gnss_upload_worker.sh` has `-f 2` (dual) not `-f 1`. Re-run install.                                 |
| RINEX contains only a few SVs                                             | Antenna / sky view. Check `receiver_probe_v3.py` C/N₀ distribution.                                           |
| `ensure_receiver.py` prints `FAILED`                                      | Cable / power / receiver lockup. Stop `gnss-capture.service`, power-cycle the F9P, start capture again.       |
| Cron jobs not firing                                                      | `sudo -u xeroth crontab -l` — if empty, re-run `install.sh --station XER?` to reinstate canonical crontab.    |

## Rebuilding a station from scratch

1. Flash Debian 13. Set hostname `MY_STATION` (or `MY_STATION`).
2. Create `xeroth` user, add NOPASSWD sudo.
3. Install Tailscale, join snareSAR tailnet, note the 100.x IP.
4. Copy `base_station/` to the station:
   `scp -r base_station/ xeroth@<ip>:/tmp/`.
5. Copy the correct `station-configs/xerN.conf` into
   `/home/xeroth/base_station/scripts/station.conf` (contains
   `STATION_ID=` and the AUSPOS XYZ coordinate).
6. `sudo /tmp/base_station/install.sh --station MY_STATION`.
7. Verify within two minutes:
   - `systemctl is-active gnss-receiver.service gnss-capture.service gnss-health.service` returns `active` for all three.
   - `ls /home/xeroth/base_station/logs/raw/` shows the currently-writing slot `.ubx`.
   - `curl http://<ip>:8080/health` returns `status: ok`.
   - `gcloud storage ls gs://xeroth-base-stations-data/MY_STATION/$(date -u +%Y/%j)/` shows fresh `.obs` and `.nav` files after the first rotation boundary has passed.
   - Download one `.obs`, confirm the four-code SYS / # / OBS TYPES lines (dual-frequency).
