# Contributing

Thanks for considering a contribution. This project deploys to real
GNSS hardware running unattended in the field; we keep the merge
bar accordingly high. Expect review even on small changes.

## Ground rules

- **One change per PR.** Don't bundle unrelated fixes.
- **Tests pass before opening the PR.** CI will catch what local
  doesn't, but please don't rely on CI to find obvious breakage.
- **No new long-lived credentials in the repo.** Service-account
  keys, API tokens, SSH private keys never get committed. The
  `.gitignore` covers most accidents; the
  [pre-commit](https://pre-commit.com/) hook in `.github/` covers
  the rest.
- **No site-specific data.** Tailscale IPs, ECEF coordinates,
  internal hostnames, personal email addresses do not belong in
  this repo. The `audit/` tree from the pre-fork era was excluded
  for exactly this reason — don't add a new one.

## Development setup

```bash
git clone git@github.com:OpenXeroth/xeroth-base-station.git
cd xeroth-base-station

# Install local dependencies (Debian/Ubuntu — adapt for your distro):
sudo apt-get install -y shellcheck bats rtklib python3 python3-serial
sudo pip3 install --break-system-packages ruff pyflakes

# Symlink rtklib binaries to /usr/local/bin/ if they aren't there
# (some distros install only to /usr/bin/):
sudo ln -sf /usr/bin/str2str /usr/local/bin/str2str
sudo ln -sf /usr/bin/convbin /usr/local/bin/convbin
```

## Running the test suite locally

```bash
# Lint:
find . -name "*.sh" -not -path "./.git/*" -print0 | xargs -0 shellcheck -x
ruff check --select=E,F,W,B,UP --target-version=py39 payload/
pyflakes payload/

# Tests:
bats -r tests/bats/
```

All four must pass before a PR is reviewable. CI runs the same set
on a JHB-hosted runner.

## What we will and won't merge

We **will** merge:

- Bug fixes with a regression test (bats or unit test) that
  reproduces the bug.
- New runbooks under `docs/runbooks/` for operational scenarios
  not yet covered.
- New `tools/` scripts that are useful to operators.
- Performance improvements with before/after measurements.
- Documentation clarifications.
- Hardware-compatibility patches (other u-blox receivers, other
  USB-serial adapters, other Linux distros) with the testing
  reported in the PR description.

We **will not** merge without discussion (open an issue first):

- Changes to `payload/scripts/apply_update.sh`'s argument contract
  (it's deliberately frozen — see `README.md`).
- Changes to the on-station filesystem layout
  (`/home/xeroth/base_station/...`).
- Changes that break backwards compatibility with the OTA channel
  pointer file format.
- New hard dependencies (the runtime closure stays small).
- Telemetry that phones home.

## Commit style

- Subject line: imperative, ≤ 72 chars, lowercase first word.
- Body: explain *why*, not just *what*. Include the operational
  observation or test that motivated the change.
- Reference any issue with `Closes #N` or `Refs #N`.

## Release process

Cutting a release is the maintainer's job; see
[`infra/RELEASE_PROCESS.md`](infra/RELEASE_PROCESS.md). The
short version: bump `VERSION`, append `CHANGELOG.md`, tag
`vX.Y.Z`, push the tag. CI does the rest.

## Reporting security issues

Do not open a public issue for security reports. See
[`SECURITY.md`](SECURITY.md).

## Code of conduct

By participating in this project you agree to the
[Contributor Covenant](CODE_OF_CONDUCT.md).
