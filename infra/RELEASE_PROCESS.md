# Release process

How to cut a new release of `xeroth-base-station`. This runs on
every release the project has ever cut, including v1.1.0.

Releases are GitHub tags of the form `vMAJOR.MINOR.PATCH` (e.g.
`v1.1.0`, `v1.2.0-canary.1`). The `release.yml` workflow triggers
on tag push and publishes the tarball to
`gs://${RELEASE_BUCKET}/base_station/v${VERSION}/`. After the
tarball is in place, an operator (or scripted promotion) updates
`gs://${RELEASE_BUCKET}/base_station/channels/${CHANNEL}.version`
to make the new release available to stations on that channel.

## Preflight

Run from a clone of `OpenXeroth/xeroth-base-station`:

```bash
gh auth status
gh repo view OpenXeroth/xeroth-base-station \
    --json viewerPermission --jq .viewerPermission   # expect ADMIN
gcloud config get-value project                       # expect xeroth-base-stations
gcloud auth list --filter=status:ACTIVE --format="value(account)"
git fetch --tags
```

The local working tree must be clean and on the commit you intend
to release.

## Cut the release

1. **Bump `VERSION`** to the new semver. CI gates on a strict semver
   regex (`^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$`).

2. **Append a `CHANGELOG.md` entry**. Keep it terse and operator-
   focused — what changes on the station, what an operator should
   verify after applying.

3. **Commit + push**:

   ```bash
   VERSION=$(cat VERSION)
   git commit -am "base_station v${VERSION}"
   git push origin main
   ```

4. **Tag and push the tag** — the tag is the workflow trigger:

   ```bash
   git tag -a "v${VERSION}" -m "base_station v${VERSION}"
   git push origin "v${VERSION}"
   ```

5. **Watch the workflow**:

   ```bash
   RUN_ID=$(gh run list --workflow=release \
       --limit 5 --json databaseId,event,status,createdAt \
       --jq '[.[] | select(.event=="push")] | sort_by(.createdAt) | last | .databaseId')

   gh run watch "${RUN_ID}" --exit-status

   gh run view "${RUN_ID}" \
       --json status,conclusion,headSha,displayTitle,url --jq '.'
   ```

   Expected outcome: `status=completed`, `conclusion=success`,
   `headSha` matches the commit you tagged.

   If the run fails at the auth step with
   `Permission 'iam.serviceAccounts.getAccessToken' denied`, the
   WIF attribute condition is not matching the GitHub token's
   `repository` claim. Check
   `infra/README.md` § "One-time provisioning" — specifically that
   the `--attribute-condition` was created with `attribute.repository ==
   'OpenXeroth/xeroth-base-station'` and not a different repo
   string.

   If it fails with `invalid_grant`, the `GCP_WIF_PROVIDER` repo
   secret is malformed (likely a trailing newline from a stdin pipe).
   Rewrite it via `gh secret set --body '<literal>'`. See
   `infra/README.md` for the gotcha.

   If it fails with `tag X does not match VERSION file Y`, your
   `VERSION` and tag are out of sync — fix and re-tag.

## Verify the published artefacts

```bash
RELEASE_BUCKET=gs://xeroth-base-stations-releases
VERSION=$(cat VERSION)

gcloud storage ls -l "${RELEASE_BUCKET}/base_station/v${VERSION}/"

# Verify SHA-256
gcloud storage cp "${RELEASE_BUCKET}/base_station/v${VERSION}/base_station-v${VERSION}.tar.gz" /tmp/
gcloud storage cp "${RELEASE_BUCKET}/base_station/v${VERSION}/base_station-v${VERSION}.tar.gz.sha256" /tmp/
ACTUAL=$(sha256sum /tmp/base_station-v${VERSION}.tar.gz | awk '{print $1}')
EXPECTED=$(tr -d '[:space:]' < /tmp/base_station-v${VERSION}.tar.gz.sha256)
[ "${ACTUAL}" = "${EXPECTED}" ] && echo "SHA256 OK" || echo "SHA256 MISMATCH"
```

## Promote to a channel

Stations read the channel pointer to decide what to install. Until
this step runs, no station picks up the new release.

```bash
RELEASE_BUCKET=gs://xeroth-base-stations-releases
VERSION=$(cat VERSION)
CHANNEL=stable   # or 'canary' for pre-release builds

printf '%s\n' "${VERSION}" | gcloud storage cp - \
    "${RELEASE_BUCKET}/base_station/channels/${CHANNEL}.version"

gcloud storage cat "${RELEASE_BUCKET}/base_station/channels/${CHANNEL}.version"
```

The pointer file is plain text — one semver, one trailing newline.
Object versioning is on for the releases bucket so the history of
channel-pointer moves is preserved.

## Verify a station picks up the release

Stations poll every 10 minutes. To avoid waiting, force a poll by
running the OTA agent on demand:

```bash
ssh <station-host> 'sudo -u xeroth /home/xeroth/base_station/scripts/gnss_update_agent.sh'

ssh <station-host> 'tail -n 30 /home/xeroth/base_station/state/updates.log'

ssh <station-host> "curl -s http://\$(tailscale ip -4):8080/health" \
    | python3 -m json.tool | grep -E '"version"|"target_version"|"last_update_result"'
```

Expected: the `updates.log` tail contains an `UPDATE_CHECK` line for
the new target version followed by `DOWNLOAD_OK`, `INSTALL_OK`, and
`HEALTH_OK`. The `/health` `release.version` matches the new
version. `status` is `"ok"`. `last_update_result` is `"ok"`.

If `/health` returns a `degraded` status with reasons after the
install, do NOT roll the channel pointer back blindly. The previous
binary is still on disk under `/home/xeroth/base_station/staging/`;
inspect the install log there before deciding.

## Roll back

Same mechanism, opposite direction:

```bash
RELEASE_BUCKET=gs://xeroth-base-stations-releases
PREVIOUS=1.1.0   # the version you want stations to return to
CHANNEL=stable

printf '%s\n' "${PREVIOUS}" | gcloud storage cp - \
    "${RELEASE_BUCKET}/base_station/channels/${CHANNEL}.version"
```

Stations on the next poll will see the channel pointer name an
older version, fetch its tarball (still in the bucket — releases
are never deleted), and install. The downgrade path works because
`gnss_update_agent.sh` compares strings, not semver ordering.

## What NOT to do

- Do not edit the published tarball or its `.sha256` sidecar. If a
  release is bad, cut a new patch release; the previous tag stays.
- Do not delete release objects. The CHANGELOG and the bucket
  contents are the two halves of the release audit trail.
- Do not change `payload/scripts/apply_update.sh`'s argument
  contract. It is frozen — see the top-of-file comment in that
  script and `README.md` § "OTA contract — what NOT to change".
- Do not force-push tags. Cut a new version.
