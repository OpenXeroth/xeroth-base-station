# Security policy

## Supported versions

Only the most recent minor release on the `stable` channel receives
security fixes. Stations on `canary` receive fixes ahead of the
channel cut.

| Version | Status | Notes |
|---|---|---|
| 1.1.x | Supported | Current `stable`. |
| < 1.1 | End of life | Predates the open-source release; no fixes. |

The on-station OTA agent pulls fixes automatically once a new
`stable.version` pointer is published; operators do not need to
take action for routine patches.

## Reporting a vulnerability

Email **security@xeroth.ai** with:

- A description of the issue and the impact you've established or
  suspect.
- A proof-of-concept or reproduction steps.
- The version (`/health` `release.version`) of the station the
  issue was observed on, if applicable.
- Any mitigations you've already identified.

Please **do not** open a public GitHub issue for a security report.
We will acknowledge receipt within 72 hours and aim to ship a fix
within 14 days for confirmed high-severity issues.

If you would like to encrypt the report:

- PGP key fingerprint: *to be published — until then, contact us
  via the email above to arrange an encrypted channel.*

## Scope

The following are in scope:

- The on-station services (`gnss-capture`, `gnss-health`,
  `gnss_upload_worker`, `gnss_update_agent`, `apply_update`,
  `gnss-disk-guard`, `gnss-watchdog`).
- The sudoers fragments installed by `install.sh`.
- The OTA delivery pipeline (release tarball construction,
  SHA-256 sidecar, channel pointer semantics).
- The GitHub Actions release workflow's Workload Identity
  Federation configuration.
- The IaC under `infra/` insofar as it constrains real GCP IAM.

The following are out of scope (please report to the relevant
upstream):

- `str2str`, `convbin`, and the rest of RTKLIB (see
  [RTKLIB issues](https://github.com/tomojitakasu/RTKLIB)).
- The Google Cloud SDK (`gcloud`).
- Tailscale.
- The Linux kernel or distribution-level packages.

## Out-of-band sensitive information

If you discover sensitive information (credentials, private keys,
internal hostnames, PII) accidentally committed to this repository's
git history, email **security@xeroth.ai** rather than opening an
issue. We will rotate any exposed credentials and rewrite the
history if appropriate.
