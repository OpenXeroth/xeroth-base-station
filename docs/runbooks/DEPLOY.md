# Runbook — Deploy a new station

End-to-end procedure for bringing up a new base station from bare
metal to first verified RINEX upload. Assumes the hardware is
assembled (u-blox ZED-F9P + antenna + USB-serial + Linux host) and
that the host is on Tailscale.

## Prerequisites

On your laptop:

- Tailscale, with admin access to the tailnet the station joins.
- `ssh` to `xeroth@<station-host>` working.
- `gcloud` authenticated as an owner of the GCP project that owns
  `gs://xeroth-base-stations-data` and `gs://xeroth-base-stations-releases`.

On the station host:

- Debian/Ubuntu-class Linux (the reference is RPi OS bookworm on a
  Pi 5; Ubuntu 22.04+ also tested).
- `rtklib` providing `/usr/local/bin/str2str` and `/usr/local/bin/convbin`.
- `gcloud`, `tailscale`, `python3` (3.9+), `python3-serial`.
- A `xeroth` Linux user with home at `/home/xeroth`.
- The u-blox receiver enumerated at `/dev/ttyUSB0`. If your USB-serial
  cable enumerates elsewhere, fix the `dev-ttyUSB0.device` reference
  in `payload/systemd/gnss-capture.service` before running install.sh.

## 1. Stage the station service account and key

On your laptop, create a per-station SA with prefix-scoped write to
the data bucket (see `infra/README.md` § "Per-station uploader
service account" for the IAM details):

```bash
PROJECT=xeroth-base-stations
STATION=MY_STATION
SA_ID="station-${STATION,,}-uploader"

gcloud iam service-accounts create "${SA_ID}" \
    --project="${PROJECT}" \
    --display-name="GNSS station ${STATION} uploader"

gcloud storage buckets add-iam-policy-binding \
    gs://xeroth-base-stations-data \
    --role=roles/storage.objectUser \
    --member="serviceAccount:${SA_ID}@${PROJECT}.iam.gserviceaccount.com" \
    --condition="title=${STATION}-prefix-only,expression=resource.name.startsWith('projects/_/buckets/xeroth-base-stations-data/objects/${STATION}/')"

gcloud storage buckets add-iam-policy-binding \
    gs://xeroth-base-stations-releases \
    --role=roles/storage.objectViewer \
    --member="serviceAccount:${SA_ID}@${PROJECT}.iam.gserviceaccount.com"

gcloud iam service-accounts keys create /tmp/${SA_ID}.json \
    --iam-account="${SA_ID}@${PROJECT}.iam.gserviceaccount.com"
```

Transfer to the station:

```bash
scp /tmp/${SA_ID}.json xeroth@<station-host>:/tmp/
ssh xeroth@<station-host> "sudo install -m 0600 -o xeroth -g xeroth \
    /tmp/${SA_ID}.json /home/xeroth/base_station/gnss-uploader-key.json"
```

On the station, activate:

```bash
sudo -u xeroth gcloud auth activate-service-account \
    --key-file=/home/xeroth/base_station/gnss-uploader-key.json

sudo -u xeroth gcloud auth list --filter=status:ACTIVE \
    --format="value(account)"
```

Expected: prints `station-my_station-uploader@xeroth-base-stations.iam.gserviceaccount.com`.

## 2. Stage station.conf

You need ECEF ARP coordinates for the antenna phase centre. Obtain
via 24+ hours of static observation post-processed through AUSPOS
(Geoscience Australia), OPUS (US NGS), or equivalent PPP service.
The mm-cm precision matters for PPK; do not skip this step.

On the station:

```bash
sudo mkdir -p /home/xeroth/base_station/scripts
sudo cp /path/to/checked-out-repo/station-configs.example/example.conf \
        /home/xeroth/base_station/scripts/station.conf
sudo chown -R xeroth:xeroth /home/xeroth/base_station

sudo -u xeroth nano /home/xeroth/base_station/scripts/station.conf
# Set STATION_ID. Put your ECEF X Y Z on the first non-comment line.
```

If you don't have coords yet, leave the placeholder `0.0000 0.0000
0.0000` line. The upload worker detects this sentinel and skips
APPROX POSITION XYZ injection. Replace as soon as you have AUSPOS
results — until then, downstream PPK has to estimate the position
from the observations.

## 3. Run install.sh

Clone the repo on the station and run the installer:

```bash
git clone https://github.com/OpenXeroth/xeroth-base-station.git
cd xeroth-base-station

sudo ./install.sh --station MY_STATION
```

The installer is idempotent — it can be re-run any time. On first
run it:

- Creates `/home/xeroth/base_station/{scripts,state,logs,logs/raw,staging}`.
- Installs `gnss_upload_worker.sh`, `gnss_update_agent.sh`,
  `apply_update.sh`, `ensure_receiver.py`, `gnss-watchdog.sh`,
  `gnss-disk-guard.sh`, `gnss_health.py` under
  `/home/xeroth/base_station/scripts/`.
- Installs `gnss-capture.service` and `gnss-health.service` to
  `/etc/systemd/system/`, enables and starts both.
- Masks the legacy `gnss-receiver.service` if found.
- Installs two sudoers fragments under `/etc/sudoers.d/`:
  - `gnss-watchdog` — allows `xeroth` to restart `gnss-capture.service`.
  - `gnss-update-agent` — allows `xeroth` to invoke the OTA apply
    wrapper against `/home/xeroth/base_station/staging/*/base_station`
    paths only.
- Installs the canonical crontab for `xeroth`:
  - `gnss_upload_worker.sh` every minute
  - `gnss-watchdog.sh` every minute
  - `gnss-disk-guard.sh` every 5 minutes
  - `gnss_update_agent.sh` every 10 minutes
- Records the deployed version to `/home/xeroth/base_station/state/version`.
- Sets `/home/xeroth/base_station/state/channel` to `stable` (or
  `canary` if the deployed VERSION carries a pre-release suffix).

## 4. Verify

```bash
# Capture service is running:
sudo systemctl is-active gnss-capture.service
# expect: active

# Health endpoint is up:
curl -s http://$(tailscale ip -4):8080/health | python3 -m json.tool
# expect: "status": "ok", "release.version": "<your version>",
#         "capture_service_active": true, "gcs_auth_active": true,
#         "current_slot.present": true

# The current 10-min slot has a file that is growing:
ls -la /home/xeroth/base_station/logs/raw/
# expect: one .ubx file with mtime within the last few seconds

# Wait at least one full 10-minute slot, then:
ls -la /home/xeroth/base_station/logs/raw/
# expect: the previous slot's .ubx is gone (uploaded + deleted)

# Check GCS:
gcloud storage ls gs://xeroth-base-stations-data/MY_STATION/$(date -u +%Y)/$(date -u +%j)/
# expect: .obs and .nav files for the closed slot
```

If `/health` is not `ok`, run the AUDIT runbook to diagnose.

## 5. Pin the channel (optional)

By default, install.sh sets the channel based on the VERSION suffix.
To pin a station to `canary` for field trialling new releases:

```bash
echo canary | sudo -u xeroth tee /home/xeroth/base_station/state/channel
```

To return to `stable`:

```bash
echo stable | sudo -u xeroth tee /home/xeroth/base_station/state/channel
```

The next `gnss_update_agent.sh` run (within 10 minutes) will poll the
chosen channel's pointer file.

## What to do if step 4 fails

- **`gnss-capture.service` is inactive**: `journalctl -u gnss-capture.service -n 100`.
  Most common: `/dev/ttyUSB0` not present (check FTDI cable) or
  `str2str` not found (install rtklib).

- **`/health` returns `degraded` with `gcs_auth_active: false`**:
  Re-run `gcloud auth activate-service-account` as `xeroth`.

- **`/health` returns `degraded` with `current slot file stale`**:
  receiver wedged. `sudo systemctl restart gnss-capture.service`.
  If it stays wedged, `ensure_receiver.py` needs to be run manually
  to re-apply CFG-VALSET — `sudo -u xeroth /home/xeroth/base_station/scripts/ensure_receiver.py`.

- **No files appearing in GCS after a slot has closed**:
  `tail -n 50 /home/xeroth/base_station/logs/automation.log` —
  upload-worker errors appear here. Check IAM binding scoped to the
  right station prefix.
