# Xeroth Base Station

Unattended, continuously-capturing GNSS base station for PPK/RTK
workflows. Records dual-frequency raw observations from a u-blox
ZED-F9P receiver on UTC 10-minute boundaries, converts each closed
slot to RINEX 3.03, and uploads the result to Google Cloud Storage.
Includes a pull-based OTA updater, a ring-buffer disk guard, a
versioned `/health` HTTP endpoint, a systemd-managed `str2str`
capture supervisor, and 34 bats tests covering every shell entry
point.

Designed for the case where the station is somewhere unattended on
an intermittent link behind NAT, and the operator wants to be sure
that capture is continuous, uploads catch up automatically when
connectivity returns, software updates apply without manual
intervention, and the disk never fills.

## Hardware

The reference deployment is:

- u-blox ZED-F9P-04B receiver (the Ardusimple simpleRTK2B Lite board
  is one tested carrier), connected by FTDI FT232R USB-serial.
- Linux host on aarch64 (Raspberry Pi 5) or x86_64.
- A survey-grade dual-frequency GNSS antenna with a clear sky view.
- Tailscale for management-plane access (the `/health` endpoint
  binds only to the 100.64.0.0/10 CGNAT range, never to the WAN).

Other u-blox dual-frequency receivers should work with minor
adjustments to `ensure_receiver.py`'s CFG-VALSET block. Single-
frequency receivers are out of scope.

## Software dependencies

Installed by the operator before `install.sh`:

- `rtklib` (specifically `str2str` and `convbin` from any RTKLIB
  build that supports RINEX 3.03 and u-blox UBX RAWX decoding).
- `gcloud` (the Google Cloud SDK). The station authenticates to GCS
  via a service-account key file.
- `tailscale`, configured and logged in.
- `python3` (3.11+ in the test matrix; 3.9+ should work).

## Architecture

```
                +------------------+
                |   gnss-capture   |   <-- systemd unit; resident str2str
                |   (str2str)      |       writes UBX with -f 30 swap margin
                +--------+---------+       to logs/raw/%Y%m%d%h%M.ubx
                         |
                         v
                +------------------+
                |  logs/raw/       |   <-- 10-minute closed-slot UBX files
                +--------+---------+
                         |
                         v cron 1 min
                +------------------+   convbin -v 3.03 -f 2 -r ubx
                |  upload_worker   |   inject APPROX POSITION XYZ
                |  (convbin + GCS) |   gcloud storage cp to data bucket
                +--------+---------+   delete local on verified upload
                         |
                         v
                +------------------+
                |   GCS data       |   gs://${DATA_BUCKET}/${STATION_ID}/
                |   bucket         |     ${YYYY}/${DOY}/...
                +------------------+
```

In parallel:

- `gnss-health.service` exposes a JSON `/health` endpoint on
  `http://${TAILSCALE_IP}:8080/`. Returns HTTP 200 / `status: "ok"`
  when capture, upload, disk, GCS auth, and OTA state all check out;
  HTTP 503 / `status: "degraded"` with a `reasons` array otherwise.
- `gnss-watchdog.sh` runs every minute; restarts `gnss-capture.service`
  if str2str has stalled.
- `gnss-disk-guard.sh` runs every 5 minutes; protects the 3 newest
  closed slots + the live slot, deletes older raw files when disk
  free falls below threshold.
- `gnss_update_agent.sh` runs every 10 minutes; polls
  `gs://${RELEASE_BUCKET}/base_station/channels/${CHANNEL}.version`,
  fetches and SHA-256 verifies the tarball when the pointer moves,
  invokes a narrowly-scoped sudo wrapper (`apply_update.sh`) to
  install. Failed installs leave the previous version running.

The full design is in [`docs/OPERATIONS.md`](docs/OPERATIONS.md).

## Quickstart

```bash
# 1. Install runtime dependencies (Debian/Ubuntu example):
sudo apt-get install -y rtklib python3 python3-serial
# Install gcloud per https://cloud.google.com/sdk/docs/install
# Install tailscale per https://tailscale.com/download

# 2. Create the xeroth user the install.sh expects:
sudo useradd -r -m -d /home/xeroth -s /bin/bash xeroth

# 3. Stage a station.conf for your station:
sudo mkdir -p /home/xeroth/base_station/scripts
sudo cp station-configs.example/example.conf \
        /home/xeroth/base_station/scripts/station.conf
sudo chown -R xeroth:xeroth /home/xeroth/base_station
# Edit station.conf: set STATION_ID and put your ECEF ARP coords on
# the first non-comment line. Obtain coords via AUSPOS, OPUS, or
# similar PPP service from a long static observation.

# 4. Stage your GCS uploader service-account key (see infra/README.md):
sudo install -m 0600 -o xeroth -g xeroth \
    /path/to/your-uploader-sa-key.json \
    /home/xeroth/base_station/gnss-uploader-key.json
sudo -u xeroth gcloud auth activate-service-account \
    --key-file=/home/xeroth/base_station/gnss-uploader-key.json

# 5. Run the installer (idempotent — safe to re-run):
sudo ./install.sh --station MY_STATION

# 6. Verify:
sudo systemctl status gnss-capture.service gnss-health.service
curl -s http://$(tailscale ip -4):8080/health | python3 -m json.tool
```

## Repository layout

```
.
├── LICENSE                       # Apache-2.0
├── README.md                     # this file
├── CHANGELOG.md                  # versioned release notes
├── VERSION                       # single-line semver; CI gates on it
├── install.sh                    # idempotent installer
├── payload/
│   ├── scripts/
│   │   ├── gnss_update_agent.sh  # pull-based OTA agent
│   │   ├── apply_update.sh       # narrowly-scoped sudo wrapper (FROZEN)
│   │   ├── gnss_upload_worker.sh # convbin + GCS upload + retry
│   │   ├── ensure_receiver.py    # CFG-VALSET on UART1
│   │   └── log_and_upload.sh     # legacy single-cycle utility
│   ├── hardening/
│   │   ├── gnss-watchdog.sh
│   │   ├── gnss-disk-guard.sh
│   │   └── gnss_health.py        # /health HTTP server
│   └── systemd/
│       ├── gnss-capture.service
│       ├── gnss-health.service
│       └── gnss-receiver.service # legacy; install.sh masks it
├── station-configs.example/
│   └── example.conf              # template; copy to /home/xeroth/...
├── infra/
│   ├── README.md                 # GCS buckets + WIF setup
│   ├── RELEASE_PROCESS.md        # how to cut a release
│   ├── gcs-lifecycle-data.json
│   └── gcs-lifecycle-releases.json
├── docs/
│   ├── OPERATIONS.md             # full architecture and ops reference
│   └── runbooks/
│       ├── DEPLOY.md             # deploy from scratch onto a host
│       ├── AUDIT.md              # non-destructive end-to-end audit
│       └── OFFLINE_DRILL.md      # week-long disconnection drill
├── tests/
│   └── bats/                     # 34 tests covering every shell entry
└── tools/                        # one-off operator utilities
```

## OTA contract — what NOT to change

`payload/scripts/apply_update.sh` has a **frozen contract**. The
sudoers fragment installed by `install.sh` whitelists exactly:

```
${USER} ALL=(root) NOPASSWD: \
    /home/xeroth/base_station/scripts/apply_update.sh \
        /home/xeroth/base_station/staging/*/base_station
```

Changing the staging path shape, or changing the wrapper's argument
contract, breaks the very next OTA on every station already running
this code. The wrapper is intentionally minimal and parameter-free
for this reason. Other parts of the codebase can evolve; this one
cannot, except via a deliberate flag-day migration co-ordinated
across the entire fleet.

## License

Apache-2.0. See [LICENSE](LICENSE).

This project shells out to `str2str` and `convbin` from RTKLIB
(BSD-licensed) and the `gcloud` CLI (Apache-2.0). Neither is
statically linked or vendored.

## Status

This is the deployed software running real GNSS base stations. The
v1.1.0 release is operationally identical to its pre-fork ancestor,
plus the identifier scrub for open-source publication. Bug reports
and operator feedback welcome.
