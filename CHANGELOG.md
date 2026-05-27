# Changelog — Xeroth Base Station

All notable changes to the base station software ship here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
every release is tagged with its semver in git (`vMAJOR.MINOR.PATCH`).

The on-station state file `/home/xeroth/base_station/state/version`
records what is actually deployed at each box.

## [1.1.1] — 2026-05-27

Patch release covering the cosmetic OTA-probe race observed during
the v1.0.2 → v1.1.0 cutover on XER2, plus pre-public governance and
release-pipeline hardening.

Operator-visible changes:

- **OTA agent post-install health probe is now resilient to slow
  `gnss-health.service` re-binds.** `gnss_update_agent.sh` waits
  15 s (was 5 s) before its first probe, then retries up to 3 times
  with a 5 s gap. Tunable via `HEALTH_PROBE_INITIAL_SLEEP_S`,
  `HEALTH_PROBE_RETRIES`, `HEALTH_PROBE_RETRY_SLEEP_S` env vars on
  the cron line for stations on slow networks. Eliminates the
  cosmetic `last_update_result: health_check_failed` that appeared
  after every successful install on v1.1.0.
- **No script behaviour changes beyond the probe.** Capture, upload
  worker, disk guard, watchdog, install path: all unchanged.

Release-pipeline changes:

- **SBOM** (SPDX JSON) now ships in every release bucket alongside
  the tarball and SHA-256 sidecar. Operators and auditors can diff
  it against the on-station filesystem to confirm exactly what was
  applied.
- **GitHub Actions pinned to commit SHAs** in `ci.yml` and
  `release.yml` (was floating `@v4` / `@v2` tags). Prevents a
  supply-chain attack via tag re-pointing on upstream actions from
  compromising the release SA.
- **Dependabot** opens weekly PRs for action-version updates.
- **CodeQL** runs on every push, every PR, and weekly on schedule.

Repo governance:

- `SECURITY.md` — disclosure policy and reporting channel.
- `CONTRIBUTING.md` — development setup and merge bar.
- `CODE_OF_CONDUCT.md` — adopts Contributor Covenant 2.1.
- `infra/README.md` § "Per-station uploader" now documents that
  unconditional `roles/storage.objectUser` on the data bucket is
  the correct grant. The previous example using a
  `resource.name.startsWith(...)` IAM condition does not work for
  `gcloud storage cp` (the precheck list operation is bucket-level
  and the condition evaluates to false against the bucket
  resource). Per-station isolation comes from each station having
  its own SA, not from prefix-scoped IAM.

## [1.1.0] — 2026-05-27

First release under `OpenXeroth/xeroth-base-station`. The code is
operationally identical to its predecessor `base-station-v1.0.2`
under `XerothAILimited/snareSAR` plus the changes required to
re-home it as a stand-alone open-source project.

Operator-visible changes:

- **GCS buckets renamed.** `gnss_update_agent.sh` now polls
  `gs://xeroth-base-stations-releases/base_station/channels/${CHANNEL}.version`
  and `gnss_upload_worker.sh` writes to
  `gs://xeroth-base-stations-data/${STATION_ID}/${YYYY}/${DOY}/`.
  Stations running v1.0.2 against the previous buckets do NOT
  pick up v1.1.0 automatically — see "Migration from v1.0.2" below.
- **Service-account model changed.** Each station now uses a
  per-station SA with `roles/storage.objectUser` scoped to its own
  prefix on the data bucket via a resource-name IAM condition. The
  previous shared SA model is unsupported. See
  `docs/runbooks/DEPLOY.md` § 1 for the new flow.
- **`gnss-uploader-key.json`** path on-station is unchanged.

Internal / pipeline changes:

- **Release pipeline moved** to the new repo's GitHub Actions, with
  Workload Identity Federation against the GCP project
  `xeroth-base-stations` (project number `546437991539`).
- **Apache-2.0 license** added at repo root.
- **Identifier scrub.** Internal hostnames, tailnet IDs, ECEF
  coordinates, internal e-mail addresses, and audit artefacts from
  the previous repo have been removed. Engineering history pre-dating
  this release is preserved below; the `XER1`/`XER2` references in
  v1.0.0 / v1.0.1 / v1.0.2 entries describe the stations on which
  the original work was validated and stand as historical record.
- **Internal-only docs dropped.** `CICD_PLAN.md`, `CONTROL_PLANE_DESIGN.md`,
  `FLEET_ROADMAP.md`, `HANDOFF_REPORT.md`, `STATIONS.md`,
  `DUAL_FREQUENCY_VERIFICATION.md` — these were planning docs and
  site-specific evidence files that do not belong in the public
  repo. Their engineering content is captured in `OPERATIONS.md`
  and the runbooks.
- **Runbooks renamed.** `XER1_DEPLOY.md` → `DEPLOY.md`,
  `XER2_AUDIT.md` → `AUDIT.md`. Both rewritten as station-agnostic.
- **Site-specific station configs removed.** `station-configs/xer1.conf`
  and `xer2.conf` replaced with `station-configs.example/example.conf`.

Migration from v1.0.2:

- The OTA path from a v1.0.2 station to v1.1.0 requires either
  (a) a one-time SSH-edit on each station to repoint its
  `RELEASE_BUCKET` variable at the new bucket, plus an SA key with
  read access to the new releases bucket, then trigger the agent;
  or (b) dual-publishing v1.1.0 to the old AND new release buckets
  so the v1.0.2 agent on the old bucket can pull it. Option (a) is
  simpler when SSH access is available.
- The `apply_update.sh` argument contract (staging path regex) is
  **unchanged**. v1.1.0 installs cleanly via the wrapper that's
  already on every v1.0.2 station.

## [1.0.2] — 2026-04-24

Watchdog + health-check filename logic corrected. `gnss-watchdog.sh` and
`gnss_health.py` both treated the canonical 10-minute UTC slot id as if
it were the filename str2str would write. In reality str2str names its
first-after-start file by the current minute at file-open time, not by
the 10-minute boundary, so the two only coincided when str2str happened
to start exactly on a boundary. The result was that `/health` reported
`current slot file missing` whenever capture started off-boundary, and
the watchdog restarted `gnss-capture.service` every 3 minutes (= the
backoff window) on that same mismatch — each restart created another
off-boundary filename, perpetuating the loop and costing ~3 s of data
per cycle. Observed in the field on XER2 post-reboot on 2026-04-24
after a water-ingress power event; the stations were still producing
correct dual-frequency RINEX the whole time, the bug was monitoring/
restart noise, not capture loss, but the 3-second-per-3-minute churn
would accumulate to several minutes of lost epochs over a multi-hour
flight.

### Fixed

- **`base_station/payload/hardening/gnss-watchdog.sh` — filename-agnostic
  stall check.** Watchdog now inspects the newest `.ubx` file in
  `RAW_DIR` (regardless of filename) and restarts only when its mtime
  is older than `CAPTURE_STALL_SECONDS` (60 s) or no `.ubx` file
  exists at all. Backoff interval and sudoers path unchanged.
- **`base_station/payload/hardening/gnss_health.py` — filename-agnostic
  current-slot report + raw-backlog exclusion.** `current_slot_file_status`
  now reports on the newest `.ubx` in `RAW_DIR` rather than the file
  whose name matches the canonical 10-minute-boundary id. A new
  `newest_ubx()` helper and `newest_ubx_stem()` centralise the logic.
  `raw_backlog()` excludes the newest-mtime file (the actual
  current-writing file) rather than the canonical slot. `/health` now
  reports both the actual filename stem and the canonical slot id so
  downstream consumers can see a mismatch if they want to.

### Added

- **`current_slot.canonical_slot` field in `/health`.** The existing
  `slot` field now holds the actual filename stem str2str is writing
  to; `canonical_slot` holds the id of the current 10-min UTC boundary
  window. Pre-v1.0.2 consumers that treated `slot` as canonical still
  work — the field is still populated, it just reflects reality rather
  than a derived expectation.
- **`base_station/infra/README.md` — note on `gh secret set --body`
  vs stdin.** The first real run of the v1.0.1 release workflow
  failed at the GCP auth step with `invalid_request: "Invalid value
  for audience"` because `gh secret set ... --body -` (stdin) in gh
  2.75.1 stored bytes Google STS rejected, despite `cmp` confirming
  the sent bytes exactly matched the provider's canonical resource
  name. Rewriting the same secret via `gh secret set --body '<literal>'`
  made the run succeed on the same commit and tag. Documented so the
  next operator avoids the stdin form.
- **`base_station/infra/CLI_RELEASE_TRIGGER_PROMPT.md`** — operator
  artefact from the v1.0.1 release-trigger session. Now uses the
  `--body '<literal>'` form for the secret write.

### Known limitations

- Cascading to the repo does not automatically update running
  stations. XER2 was patched in-place during the incident; other
  stations (XER1, future) will converge when the OTA agent polls the
  `stable` channel and downloads v1.0.2.
- The OTA agent on XER2 cannot currently read the releases bucket —
  `gnss-uploader@xeroth-base-stations.iam.gserviceaccount.com` has read/
  write on `gs://xeroth-base-stations-data` but not on `gs://xeroth-base-stations-releases`.
  Grant `roles/storage.objectViewer` on the releases bucket when
  convenient. Not a flight gate; XER2 is already on v1.0.2 once this
  release lands and the script is in place.

## [1.0.1] — 2026-04-21

Corrective release. v1.0.0 shipped with several pieces of repo-side
infrastructure that were inconsistent with the live cloud state and
with the running code. No on-station behavioural changes land in this
bump — the station code is byte-identical to v1.0.0. Everything here is
a repo / release-pipeline / runbook correction required to make v1.0.0
actually consumable by the OTA agent and reviewable by an auditor.

### Fixed

- **Release workflow tag trigger.** `.github/workflows/base-station-release.yml`
  was triggered on `base_station-v*` (underscore). The tags we actually
  push are `base-station-v*` (hyphen). v1.0.0's tag push ran only the
  CI workflow, not the publishing workflow — nothing landed in
  `gs://xeroth-base-stations-releases`. Trigger and the `${TAG#...}` strip both
  corrected to `base-station-v*`.
- **Release workflow GCP project.** Workflow referenced project
  `xeroth-ai`. Base stations live in `xeroth-base-stations` — Xenolith
  infrastructure, not snareSAR. All three references (`GCP_PROJECT`,
  `GCP_RELEASE_SA`, WIF provider path) corrected. The WIF provider
  path is now read from the repository secret `GCP_WIF_PROVIDER`
  because its canonical form embeds the numeric project number and
  should not be hard-coded.
- **`gcs-lifecycle-xeroth-base-stations-data.json` matches the live policy.**
  Previous JSON in the repo proposed a `STANDARD → NEARLINE → COLDLINE
  → Delete@2555` tiered policy that was never applied and does not
  match the live bucket, which is single-rule `Delete` at `age=90`
  (intentional — PPK work against a mission is done within days of
  capture). The repo JSON now matches the live state and is apply-safe.
- **Runbook `/health` schema assertions.** `XER1_DEPLOY.md`,
  `XER2_AUDIT.md`, and `OFFLINE_DRILL.md` asserted against nested
  fields (`h['capture']['status']`, `h['upload']['heartbeat_age_seconds']`)
  that the code in `gnss_health.py` never produced. The code emits
  flat top-level keys: `capture_service_active`,
  `current_slot.{present,age_seconds}`, `upload_heartbeat.{age_seconds,state}`,
  `release.{version,channel,update_pending}`, `disk.free_mb`,
  `raw_backlog.count`, `rinex_backlog_count`. All three runbooks
  rewritten to match. Under the previous wording the audit would have
  failed on the first assertion on any station regardless of its
  actual state.

### Added

- **`base_station/infra/README.md` — provisioning runbook for the
  releases bucket.** Documents that `gs://xeroth-base-stations-releases` must be
  created in `xeroth-base-stations` (previously assumed to exist), the
  exact `gcloud` invocations to create it with versioning and the
  lifecycle policy, and the one-time provisioning commands to wire up
  keyless GitHub-to-GCP auth (service account + workload identity
  pool + repo-scoped trust). Plain-language explanation of what each
  piece does so a new operator can execute without prior GCP trust
  federation experience.

### Known limitations

- `gs://xeroth-base-stations-releases` still needs to be physically created in
  `xeroth-base-stations` and the GitHub secret `GCP_WIF_PROVIDER` populated
  before `base-station-v1.0.1` will actually land a tarball. The tag
  push itself is safe — if auth or upload fails, the on-station agents
  keep running v1.0.0 (the channel pointer is not advanced until the
  tarball upload succeeds).

## [1.0.0] — 2026-04-21

First tagged release of the base station stack. Every previous
deployment was a bespoke script drop; v1.0.0 is the first version
that can be consumed by a pull-based OTA agent and rolled across the
fleet by release channel.

### Added

- **Continuous capture architecture.** `gnss-capture.service` runs a
  resident `str2str` that rotates the UBX output every 10 minutes on
  UTC `:00/:10/:20/:30/:40/:50` boundaries, replacing the legacy
  cron-based 480-second cycle. Eliminates capture gaps at the
  rotation boundary.
- **Ring-buffer disk guard.** `gnss-disk-guard.sh` descends into
  `logs/raw/`, purges oldest closed rotations once `free_mb <
  MIN_FREE_MB`, and explicitly protects the active slot + the 3
  newest closed slots. Purges are logged as `PURGED:` / `PURGE_DONE:`
  lines in `disk-guard.log`.
- **Upload worker (`gnss_upload_worker.sh`).** Runs every minute from
  cron. Converts each closed UBX rotation to RINEX 3.03 via
  `convbin -f 2`, uploads `.obs` + `.nav` to
  `gs://xeroth-base-stations-data/<STATION>/<YYYY>/<DOY>/`, and atomically deletes
  the UBX once the GCS `.obs` CRC32C matches local. Refuses to touch
  files newer than `MIN_CLOSED_AGE` seconds to avoid racing
  still-writing rotations. Skips `convbin` entirely when the matching
  `.obs`/`.nav` already exist on disk (resume-after-crash path). Also
  sweeps orphaned `.obs`/`.nav` (with or without a `.tag` sidecar)
  that pre-date the continuous-capture architecture.
- **Client-side timeout wrapper for `gcloud`.** Every upload-worker
  and update-agent invocation of `gcloud storage …` is wrapped in a
  45-second kill-on-stuck wrapper (`gcloud_cmd()`) so a stuck TCP
  connection cannot hang a cron tick indefinitely.
- **Narrow sudoers fragments.**
  - `/etc/sudoers.d/gnss-watchdog` — allows `xeroth` to restart only
    `gnss-capture.service` via the watchdog.
  - `/etc/sudoers.d/gnss-update-agent` — allows `xeroth` to invoke
    only the root-owned `apply_update.sh` against staging paths
    matching the canonical OTA layout.
    Both fragments are `0440 root:root`, validated with `visudo -cf`
    before `mv` into place.
- **OTA auto-update agent.** `gnss_update_agent.sh` runs every 10
  minutes from cron. Reads the station's `state/channel` file
  (`stable` or `canary`), fetches the channel pointer from
  `gs://xeroth-base-stations-releases/channels/`, and if the target differs from
  `state/version`, downloads the signed release tarball, verifies it,
  unpacks into `/home/xeroth/base_station/staging/<VERSION>/`, and
  invokes `sudo apply_update.sh`. `apply_update.sh` is **root-owned**
  so `xeroth` cannot tamper with the trusted entry point between
  runs; it validates its single staging-path argument against a
  strict regex before calling `install.sh`.
- **Versioned /health endpoint.** `/health` now reports `release` with
  `version`, `channel`, `update_pending`, `last_update_check_age_s`.
  Upstream consumers (fleet console, dashboards) can distinguish
  "capture ok but update pending" from "capture ok, fully up to date".
- **Log rotation for station logs.** `/etc/logrotate.d/gnss-base-station`
  keeps 7 generations of `automation.log`, `disk-guard.log`,
  `updates.log`, `gnss-health.log`.
- **Legacy `gnss-receiver.service` retirement.** The old one-shot
  receiver-config unit is disabled + masked by `install.sh` so that
  its stale `failed (start-limit-hit)` state stops confusing operators.
  Receiver configuration is now re-asserted on every start of
  `gnss-capture.service` via `ExecStartPre=`.
- **GCS bucket lifecycle policy** for both `gs://xeroth-base-stations-data` and
  `gs://xeroth-base-stations-releases` — tracked IaC under `base_station/infra/`,
  applied via `gcloud storage buckets update --lifecycle-file=…`.
- **Bats unit test harness** under `base_station/tests/bats/`. 34
  test cases covering `install.sh`, `apply_update.sh`,
  `gnss_update_agent.sh`, `gnss_upload_worker.sh`. Runs in CI.
- **GitHub Actions CI** (`.github/workflows/base-station-ci.yml`):
  - `shellcheck --severity=warning` on every shell script.
  - `bash -n` on install.sh, apply_update.sh, scripts, hardening.
  - `ruff --select E,F,W,B,UP --ignore E501` on Python sources and
    `pyflakes` as a second opinion.
  - `systemd-analyze verify` on every unit file (with `rtklib` +
    `tailscale` installed in the runner so `ExecStart=` and
    `After=tailscaled.service` resolve).
  - `bats` test job that hard-fails if the test directory is missing.
  - `VERSION` file semver regex gate.
- **Runbooks** under `base_station/docs/runbooks/`:
  - `XER1_DEPLOY.md` — deploy v1.0.0 to XER1.
  - `XER2_AUDIT.md` — non-destructive end-to-end audit of the canary.
  - `OFFLINE_DRILL.md` — 7-day outage-and-backfill drill procedure.
- **Manual utility** `base_station/tools/purge_legacy_top_level_ubx.sh`
  — dry-run-by-default cleanup of pre-v1.0.0 top-level UBX cruft.

### Changed

- **`install.sh` is now idempotent and version-aware.** Reads
  `base_station/VERSION`, validates semver, records the deployed
  version and channel into `state/version` and `state/channel`,
  preserves an existing `STATION_ID` across re-installs, and rejects
  malformed VERSION files rather than silently installing.
- **`convbin -f 1` → `convbin -f 2`.** The legacy converter flag
  collapsed dual-frequency UBX to L1-only RINEX. Every station now
  converts to full RINEX 3.03 preserving L1 + L2/L5 across GPS,
  GLONASS, Galileo, and BeiDou.
- **`gnss_health.py`:**
  - `format()` → f-string for the `listening on` banner (ruff UP032).
  - Transition-band false positives (`status=degraded` flapping at
    the minute boundary during rotation) fixed by widening the
    rotation-age grace window to one full boundary (650s).
- **`ensure_receiver.py` `build_valset()`** now handles `sz==1`
  (L-type / boolean) keys correctly — previously threw `ValueError`
  on boolean CFG keys. Error text for unknown sizes switched to
  f-string (ruff UP032).
- **`rawx_sigids.py`:** unused `Counter()` removed (F841); inner loop
  variables renamed to `_k` / `_count` so static analysis does not
  flag unused loop vars (B007).
- **`verify_keys_valset.py`:** single multi-module import split into
  one import per line (E401).
- **README.md** — payload tree rewritten for the v1.0.0 architecture;
  stale `run_install_when_free.sh` / 10-min cron references removed;
  pointers to `CICD_PLAN.md`, `FLEET_ROADMAP.md`, `CONTROL_PLANE_DESIGN.md`,
  and the new runbooks added.

### Fixed

- **Capture gaps at rotation boundary.** Cron-based 480s cycle could
  miss data while one invocation was shutting `str2str` down and the
  next hadn't yet brought it up. Continuous-capture via
  `gnss-capture.service` eliminates the window.
- **Disk guard stopped above `raw/`.** The previous implementation
  scanned only the top level of `logs/` and never reached the
  rotations. Now descends explicitly, and the protect-slot logic
  keeps the live slot + 3 newest closed slots even when free space
  is exhausted.
- **Dual-frequency regression to L1-only RINEX.** `convbin -f 1` in
  the legacy `log_and_upload.sh` was dropping L2/L5 on conversion.
  Fixed in the new upload worker (`-f 2`); legacy script retained for
  ad-hoc one-offs but no longer wired into cron or systemd.
- **`gnss-receiver.service` StartLimitIntervalSec placement.** The
  directive was under `[Service]` rather than `[Unit]`, silently
  ignored. Moot in v1.0.0 (the unit is retired) but the correct
  placement is preserved in the deploy for operator reference.
- **`/health` transition-band false positive.** See Changed.
- **UART1 baud divergence between XER1 (38400) and XER2 (115200).**
  Baud authoritative file `baud.conf` added to the deploy; both
  stations now 115200 by default, and `install.sh` seeds the file only
  if it does not already exist (operators who have deliberately pinned
  a different baud are preserved across re-installs).

### Security

- OTA agent is pull-only — stations never accept an inbound push.
- `apply_update.sh` is root-owned; xeroth's sudoers fragment allows
  only the one canonical staging path (`/home/xeroth/base_station/staging/<VERSION>/base_station`).
- `gs://xeroth-base-stations-releases` bucket uses object-versioning ON (channel
  pointer moves preserve an audit trail); `gs://xeroth-base-stations-data` uses
  object-versioning OFF (filenames are UTC-timestamped so overwrite
  is impossible by construction).

### Known limitations

- OTA signing is "verify the tarball SHA matches the channel pointer's
  recorded digest". Not GPG-signed yet. Migrate to cosign or similar
  before opening the OTA path to untrusted authors.
- No fleet-side "stop the update" control yet — a release that goes
  out must be reversed by pushing a newer tag, not by flipping a
  switch. Fleet console work (tracked in `CONTROL_PLANE_DESIGN.md`)
  addresses this.
- XER1 remains on the legacy 480s-cron architecture until
  `docs/runbooks/XER1_DEPLOY.md` is executed. Until that happens, the
  fleet runs in mixed-mode.
