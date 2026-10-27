# Xeroth Base Station

Software that turns a Raspberry Pi and a u-blox ZED-F9P receiver into an
unattended GNSS base station. It records dual-frequency raw measurements
continuously, converts each ten-minute UTC slot to RINEX 3.03, and
uploads the files to the Xeroth network, where approved users download
them for post-processed (PPK) positioning.

The guide for building one, joining the network and getting data is the
site at **[base.xeroth.ai](https://base.xeroth.ai)**, whose source is the
`site/` folder of this repository.

Built for a station somewhere unattended on an intermittent link: capture
never stops for the network, uploads catch up when the link returns, a
watchdog restarts capture if it stalls, and a disk guard keeps the card
from filling.

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
                |                  |   PUT to base.xeroth.ai/v1 with the
                +--------+---------+   station's key (or gcloud storage cp
                         |             for Xeroth's own stations);
                         v             delete local copy once stored
                +------------------+
                |  Xeroth network  |   <STATION_ID>/<YYYY>/<DOY>/...
                +------------------+
```

In parallel:

- `gnss-health.service` exposes a JSON `/health` endpoint on
  `http://${TAILSCALE_IP}:8080/` (only if Tailscale is installed). Returns
  HTTP 200 / `status: "ok"` when capture, upload, disk and OTA state check out;
  HTTP 503 / `status: "degraded"` with a `reasons` array otherwise.
- `gnss-watchdog.sh` runs every minute; restarts `gnss-capture.service`
  if str2str has stalled.
- `gnss-disk-guard.sh` runs every 5 minutes; protects the 3 newest
  closed slots + the live slot, deletes older raw files when disk
  free falls below threshold.
- `gnss_update_agent.sh` (Xeroth's own stations only, which can read
  the private release bucket) runs every 10 minutes; polls
  `gs://${RELEASE_BUCKET}/base_station/channels/${CHANNEL}.version`,
  fetches and SHA-256 verifies the tarball when the pointer moves,
  invokes a narrowly-scoped sudo wrapper (`apply_update.sh`) to
  install. Failed installs leave the previous version running.

The full design is in [`docs/OPERATIONS.md`](docs/OPERATIONS.md).

## Install

Follow [base.xeroth.ai/build](https://base.xeroth.ai/build/). In short,
on a Raspberry Pi with a user called `xeroth`, RTKLIB's `str2str` and
`convbin` in `/usr/local/bin`, and the receiver's UART1 on `/dev/ttyUSB0`:

```bash
mkdir -p /home/xeroth/base_station/scripts
cp station-configs.example/example.conf /home/xeroth/base_station/scripts/station.conf
# edit station.conf: STATION_ID, UPLOAD_KEY, and the surveyed antenna position
sudo ./install.sh
```

Xeroth's own stations upload with a Google Cloud service account instead
of a key; `docs/runbooks/DEPLOY.md` covers that.

## Repository layout

```
install.sh                 idempotent installer
payload/scripts/           upload worker, receiver set-up, OTA agent and its sudo wrapper
payload/hardening/         watchdog, disk guard, /health server
payload/systemd/           gnss-capture.service, gnss-health.service
station-configs.example/   station.conf template
tests/bats/                tests for every shell entry point
site/                      base.xeroth.ai (static pages)
worker/index.js            the Cloudflare Worker serving site/ and passing the
                           network's own paths to its service
wrangler.jsonc             Worker configuration
docs/, infra/              operations, runbooks, Xeroth's buckets and releases
```

## Site

```bash
npx wrangler@4 dev       # local preview
npx wrangler@4 deploy    # publish base.xeroth.ai (Xeroth's Cloudflare account)
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

## Licence

Apache-2.0. See [LICENSE](LICENSE). RTKLIB (BSD) and the `gcloud` CLI
are run as separate programs; neither is vendored.
