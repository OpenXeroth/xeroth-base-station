# Self-hosted GitHub Actions runner

The CI and release workflows for this repo run on a self-hosted
runner labelled `[self-hosted, jhb]`. The current runner is on the
JHB VM (`naturecam-jhb`, Ubuntu 24.04, x86_64). If you replace it
or add capacity, keep the `jhb` label so the workflows continue to
target it.

This doc is the provisioning recipe.

## Prerequisites on the runner host

The CI workflow does not install dependencies — they must be
present on the host before the runner picks up a job. Install once:

```bash
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
    git curl wget tar jq \
    rtklib shellcheck bats \
    python3 python3-pip python3-venv \
    systemd

# rtklib's str2str/convbin install into /usr/bin/ on Debian/Ubuntu.
# The systemd units in this repo reference /usr/local/bin/, so
# symlink to bridge:
sudo ln -sf /usr/bin/str2str /usr/local/bin/str2str
sudo ln -sf /usr/bin/convbin /usr/local/bin/convbin

# Python linters used by ci.yml:
sudo pip3 install --break-system-packages ruff pyflakes
```

The release workflow additionally needs internet egress to `*.googleapis.com`
(GCS upload via the WIF auth path) and `github.com` (checkout +
action downloads). No additional packages.

## Register the runner

From a machine with `gh` authenticated as a repo admin
(`OpenXeroth/xeroth-base-station`):

```bash
gh api -X POST \
    /repos/OpenXeroth/xeroth-base-station/actions/runners/registration-token \
    --jq .token
```

Tokens expire in ~1 hour. Transfer the token to the runner host,
then:

```bash
sudo mkdir -p /opt/actions-runner-xbs
sudo chown $(whoami):$(whoami) /opt/actions-runner-xbs
cd /opt/actions-runner-xbs

RUNNER_VERSION=$(curl -sSL https://api.github.com/repos/actions/runner/releases/latest \
    | jq -r '.tag_name' | sed 's/^v//')
curl -sSLO "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
tar xzf "actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
rm -f "actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

./config.sh \
    --url https://github.com/OpenXeroth/xeroth-base-station \
    --token <REG_TOKEN> \
    --name "jhb-xbs" \
    --runnergroup default \
    --labels "self-hosted,linux,x64,jhb" \
    --work _work \
    --unattended \
    --replace
```

## Install as systemd service

The repo expects the runner to keep itself alive across reboots.
Write a systemd unit (do NOT use the bundled `svc.sh install`
helper if other runners already exist on the host — its default
unit name would collide):

```ini
# /etc/systemd/system/actions-runner-xbs.service
[Unit]
Description=GitHub Actions self-hosted runner (OpenXeroth/xeroth-base-station — jhb-xbs)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=<runner-user>
Group=<runner-user>
WorkingDirectory=/opt/actions-runner-xbs
ExecStart=/opt/actions-runner-xbs/run.sh
Restart=always
RestartSec=10
TimeoutStopSec=3min
MemoryMax=4G
MemoryHigh=3G

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now actions-runner-xbs.service
systemctl status actions-runner-xbs.service
```

## Verify

```bash
gh api /repos/OpenXeroth/xeroth-base-station/actions/runners \
    --jq '.runners[] | {name, status, busy, labels: [.labels[].name]}'
```

Expect: one entry with `name=jhb-xbs`, `status=online`,
`labels` includes `self-hosted` and `jhb`.

## Security notes

- The runner executes whatever workflow code the repo contains
  at the time a job runs, with the privileges of `<runner-user>`.
  For a private repo with admin-only push access, this is
  acceptable. If you open the repo to PR contributions from
  untrusted authors, switch to GitHub-hosted runners for `pull_request`
  events, or require `workflow_dispatch` approval, or run the
  runner inside an ephemeral container.

- The runner user does not need `sudo` for CI as currently written.
  The previous `sudo apt-get install` and `sudo systemd-analyze`
  steps have been removed; `systemd-analyze verify` runs against
  the unit files directly without installing them.

- The runner can outbound-connect to `*.github.com` and to
  Google Cloud APIs (for the release workflow). If the host is on
  a restricted egress policy, allowlist both.

## De-register

To remove the runner cleanly:

```bash
sudo systemctl disable --now actions-runner-xbs.service
sudo rm /etc/systemd/system/actions-runner-xbs.service
sudo systemctl daemon-reload

cd /opt/actions-runner-xbs
gh api -X POST \
    /repos/OpenXeroth/xeroth-base-station/actions/runners/remove-token \
    --jq .token
# transfer token to runner host, then:
./config.sh remove --token <REMOVE_TOKEN>

cd /
sudo rm -rf /opt/actions-runner-xbs
```
