# Infrastructure — GCS buckets and release pipeline

Tracked IaC for the GCS buckets the fleet depends on, plus the
workload-identity-federation (WIF) configuration that lets the
GitHub Actions release workflow publish without long-lived keys.

The reference deployment lives in GCP project
**`xeroth-base-stations`** (project number `546437991539`).
Operators running their own fleet will substitute their own project.

```bash
gcloud config set project xeroth-base-stations
```

## Buckets

| Bucket | Purpose | Lifecycle |
|---|---|---|
| `gs://xeroth-base-stations-data` | Raw RINEX (.obs + .nav) uploaded by each station, prefix `${STATION_ID}/${YYYY}/${DOY}/` | Delete at 90 days. PPK is a few-days-fresh workload; archival has no fleet value. |
| `gs://xeroth-base-stations-releases` | OTA tarballs (`base_station/v${VERSION}/base_station-v${VERSION}.tar.gz` + `.sha256`) and channel pointers (`base_station/channels/${CHANNEL}.version`) | Transition to NEARLINE at 30 days. No delete — releases ARE the audit trail. Object versioning ON. |

Both bucket names are configurable in `payload/scripts/gnss_update_agent.sh`
(`RELEASE_BUCKET`) and `payload/scripts/gnss_upload_worker.sh`
(`GCP_BUCKET`). If you fork and redeploy, change them in those two
scripts and in this file.

### Create buckets

```bash
PROJECT=xeroth-base-stations

gcloud storage buckets create gs://xeroth-base-stations-data \
    --project="${PROJECT}" \
    --location=US \
    --default-storage-class=STANDARD \
    --uniform-bucket-level-access

gcloud storage buckets create gs://xeroth-base-stations-releases \
    --project="${PROJECT}" \
    --location=US \
    --default-storage-class=STANDARD \
    --uniform-bucket-level-access

gcloud storage buckets update gs://xeroth-base-stations-releases \
    --versioning
```

### Apply lifecycle policies

```bash
gcloud storage buckets update gs://xeroth-base-stations-data \
    --project="${PROJECT}" \
    --lifecycle-file=infra/gcs-lifecycle-data.json

gcloud storage buckets update gs://xeroth-base-stations-releases \
    --project="${PROJECT}" \
    --lifecycle-file=infra/gcs-lifecycle-releases.json
```

Verify:

```bash
gcloud storage buckets describe gs://xeroth-base-stations-data \
    --format='yaml(name,location,storageClass,lifecycle,iamConfiguration.uniformBucketLevelAccess)'

gcloud storage buckets describe gs://xeroth-base-stations-releases \
    --format='yaml(name,location,storageClass,versioning,lifecycle,iamConfiguration.uniformBucketLevelAccess)'
```

## Per-station uploader service account

Each station needs its own service account and key with
`roles/storage.objectUser` on `gs://xeroth-base-stations-data`, plus
read access on the releases bucket so the OTA agent can poll the
channel pointer.

```bash
PROJECT=xeroth-base-stations
STATION=MY_STATION
SA_ID="station-$(echo "${STATION}" | tr 'A-Z' 'a-z')-uploader"

gcloud iam service-accounts create "${SA_ID}" \
    --project="${PROJECT}" \
    --display-name="GNSS station ${STATION} uploader"

# Write/list/delete on the data bucket (no IAM condition — see below
# for why prefix-scoped conditions do NOT work here).
gcloud storage buckets add-iam-policy-binding \
    gs://xeroth-base-stations-data \
    --role=roles/storage.objectUser \
    --member="serviceAccount:${SA_ID}@${PROJECT}.iam.gserviceaccount.com"

# Read-only on the releases bucket so the OTA agent can poll the
# channel pointer and fetch tarballs.
gcloud storage buckets add-iam-policy-binding \
    gs://xeroth-base-stations-releases \
    --role=roles/storage.objectViewer \
    --member="serviceAccount:${SA_ID}@${PROJECT}.iam.gserviceaccount.com"

gcloud iam service-accounts keys create \
    /tmp/${SA_ID}.json \
    --iam-account="${SA_ID}@${PROJECT}.iam.gserviceaccount.com"

# Transfer /tmp/${SA_ID}.json to the station, then on the station:
#   sudo install -m 0600 -o xeroth -g xeroth /tmp/${SA_ID}.json \
#       /home/xeroth/base_station/gnss-uploader-key.json
#   sudo -u xeroth gcloud auth activate-service-account \
#       --key-file=/home/xeroth/base_station/gnss-uploader-key.json
```

### Why the SA is granted bucket-wide rather than prefix-scoped

An earlier iteration of this doc recommended a `resource.name.startsWith(...)`
IAM condition to constrain each station's writes to its own
`${STATION_ID}/` prefix. That **does not work** with the gcloud
storage client the upload worker uses.

`gcloud storage cp` performs a bucket-level destination-type
precheck (an implicit `storage.objects.list` against the bucket
root) before writing. The `resource.name` condition evaluates to
false for bucket-level operations because the resource being
checked is the bucket, not an object under the prefix — so the
copy fails with `storage.objects.list denied` even though the
specific object the SA wants to create matches the condition.

Per-station isolation is therefore achieved at the **service-account
level**: each station has its own SA and its own key file. A
compromise of one station's key gives the attacker write access to
the entire data bucket but does not give them access to any other
station's *key* and does not give them access to any other GCP
resource in the project. The blast radius is one bucket's data
contents.

A future architectural option for stronger isolation: replace the
direct GCS upload with a signed-URL upload via the rinex-api
(`POST /v1/stations/{id}/observations/upload`), which can issue
short-lived URLs scoped to a single object. That work is tracked in
[`OpenXeroth/rinex-api`](https://github.com/OpenXeroth/rinex-api).

## GitHub Actions release pipeline

The release workflow (`.github/workflows/release.yml`) runs on the
tag `v*.*.*` and publishes the tarball to
`gs://xeroth-base-stations-releases/base_station/v${VERSION}/`. It
authenticates to GCP **without a long-lived key** using Workload
Identity Federation: GitHub Actions mints a short-lived GCP
credential by exchanging its OIDC token, gated by an attribute
condition that only matches this repository.

Three things must exist in the GCP project:

1. A **service account** `github-releaser@xeroth-base-stations.iam.gserviceaccount.com`
   with exactly:
   - `roles/storage.objectUser` on `gs://xeroth-base-stations-releases`.
   - No other bindings.

2. A **workload identity pool** with a provider that only accepts
   tokens from the `OpenXeroth/xeroth-base-station` repository.

3. A **binding** allowing the pool to impersonate the service
   account from that one repository.

Store the provider's full resource path as the repository secret
`GCP_WIF_PROVIDER`. The workflow reads it at `secrets.GCP_WIF_PROVIDER`
and the service-account email is fixed in the workflow `env:` block.

### One-time provisioning

Execute from a workstation with `gcloud` authenticated as an owner
of `xeroth-base-stations`:

```bash
PROJECT=xeroth-base-stations
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')
SA=github-releaser
REPO=OpenXeroth/xeroth-base-station
POOL=github
PROVIDER=github

gcloud iam service-accounts create "${SA}" \
    --project="${PROJECT}" \
    --display-name="GitHub Actions base-station releaser"

gcloud storage buckets add-iam-policy-binding gs://xeroth-base-stations-releases \
    --role=roles/storage.objectUser \
    --member="serviceAccount:${SA}@${PROJECT}.iam.gserviceaccount.com"

gcloud iam workload-identity-pools create "${POOL}" \
    --project="${PROJECT}" --location=global \
    --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc "${PROVIDER}" \
    --project="${PROJECT}" --location=global \
    --workload-identity-pool="${POOL}" \
    --display-name="GitHub OIDC" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition="attribute.repository == '${REPO}'" \
    --issuer-uri="https://token.actions.githubusercontent.com"

gcloud iam service-accounts add-iam-policy-binding \
    "${SA}@${PROJECT}.iam.gserviceaccount.com" \
    --role=roles/iam.workloadIdentityUser \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"

# Print the provider path — copy into GitHub repo secret GCP_WIF_PROVIDER:
echo "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
```

### Setting `GCP_WIF_PROVIDER` — use `--body`, not stdin

When populating the `GCP_WIF_PROVIDER` repo secret via the `gh` CLI,
write it with `--body '<literal>'`. **Do not** pipe via stdin
(`--body -`). The first real run of an equivalent workflow on
another repo failed at the auth step with Google STS returning
`invalid_request: "Invalid value for 'audience'"` after the secret
was piped in via `printf '%s' "..." | gh secret set ... --body -`.
The bytes on the sending side were byte-identical to the provider
path (verified with `cmp`), but something in `gh` 2.75.1's stdin
read path stored a body the STS could not accept. Re-writing the
same secret with `--body '<literal>'` made the workflow succeed on
the same commit. Secret values cannot be read back, so this is
inference from a controlled A/B test, not a proof — but the
workaround is well-confirmed.

Correct form:

```bash
gh secret set GCP_WIF_PROVIDER \
    --repo OpenXeroth/xeroth-base-station \
    --body 'projects/546437991539/locations/global/workloadIdentityPools/github/providers/github'
```

## Non-goals

Per-station prefix differentiation **in the release pipeline** is
intentionally absent. A station-specific release pointer would
create pressure to promote some stations above others; the control
plane is designed to treat every station identically. Stations
opt into a channel (`stable` vs `canary`) by writing their channel
name to `/home/xeroth/base_station/state/channel` on the station
itself.

Cross-bucket replication is not built in. If you need geo-redundancy,
turn on GCS Dual-region or Multi-region at bucket creation time
rather than orchestrating cross-bucket copies.
