# Consiva.ai — Google Cloud Marketplace (classic Kubernetes app, BYOL)

Deployment artefacts for listing Consiva.ai on Google Cloud Marketplace. The AWS Marketplace
container product is unaffected by anything in this folder — it keeps using
`deploy/consiva-container-deploy.yaml` and `prm-tagging/`.

Pricing is **BYOL**: no price on the listing, customers click *Contact Sales*, Consiva invoices
directly and issues a signed Enterprise licence key whose `exp` is the contract end date. Google
is not in the payment path, so there is no metering or procurement integration here.

## Layout

| Path | Purpose |
|---|---|
| `chart/` | Helm chart — Deployment (backend + frontend), Services, Ingress, ConfigMap, Secret, Application CRD |
| `deployer/Dockerfile` | Deployer image, built `FROM gcr.io/cloud-marketplace-tools/k8s/deployer_helm` |
| `schema.yaml` | Deployer input schema shown to the customer at deploy time |
| `tests/basic-suite.yaml` | mpdev verification suite (install → probe → uninstall) |
| `apptest/chart/templates/tests.yaml` | The tester Pod `mpdev /scripts/verify` runs; packaged to `/data-test` |
| `build-images.sh` | Builds/tags/pushes all three images with the service-name annotation and release track |
| `LICENSE` | Apache-2.0. Google requires a LICENSE in the public repo |
| `USER_GUIDE.md` | The CLI deployment guide Google requires |

## Tiering

One image serves both marketplaces. `DEPLOYMENT_MODE=self-hosted` is the only flag that
switches SaaS behaviour off — there is no "GCP mode", and the app does not know which cloud it
is on.

- **Blank licence key** → Free tier.
- **Valid signed key** → Enterprise until the key's `exp`.

The signature is verified once at startup; the expiry is re-checked on every read, so a
long-running container drops back to Free the moment the term ends without needing a restart. A
background job (`licence-reconcile`, every 15 minutes plus once at startup) keeps the tenant's
subscription row in step, so plan *limits* and data-retention follow the same transition as the
feature gates. Verification is entirely offline — nothing is sent to Consiva or Google.

## Database

**This chart does not ship a database.** `db.connectionString` is a required input; point it at
Cloud SQL for SQL Server or your own instance. This mirrors the AWS template, where the database
is RDS and lives outside the application, and keeps customer consent data on managed storage
with the customer's own backup and retention policy.

The connection string must include `;IPAddressPreference=IPv4First` — it works around a
`Microsoft.Data.SqlClient` fault resolving IPs on Linux containers.

## Local verification

```bash
helm template consiva ./chart \
  --set db.connectionString="Server=...;IPAddressPreference=IPv4First;" \
  --set jwt.secret="$(openssl rand -base64 48)" \
  --set smtp.host=smtp.example.com --set smtp.username=u \
  --set smtp.password=p --set smtp.fromEmail=noreply@example.com \
  --set appDomainUrl=http://localhost

# Against a local cluster (kind/minikube), following Google's mpdev reference:
mpdev /scripts/install --deployer=<deployer-image> --parameters='{...}'
mpdev /scripts/verify   --deployer=<deployer-image>
```

> **Run, and passing, 2026-10-07.** `helm lint`, `helm template`, and the full
> `mpdev /scripts/install` + `mpdev /scripts/verify` cycle were run against a local kind cluster
> with SQL Server as an in-cluster container. Verify ends `PASSED`, with the tester reporting
> `backend /health -> 200`, `backend /api/v1/domains -> 401`, `frontend / -> 307`.

Two real packaging bugs were found this way, and only this way — both are fixed:

1. **The deployer shipped the chart as a directory.** The base image globs `/data/chart` for
   `*.tar.gz`, so a directory produced `Error: path "/data/extracted/*/chart" not found`. The
   extension must be `.tar.gz` (`.tgz` is not matched) and the archive's top-level directory must
   be named exactly `chart` — which a plain `helm package` artefact is not. `build-images.sh` now
   packages it.
2. **`tests/basic-suite.yaml` was wired to nothing.** There was no `/data-test` payload at all, so
   verification would have run zero tests. It also targets a `tester` image Google no longer
   publishes (`gcr.io/cloud-marketplace-tools/k8s/tester` returns 404). The checks now run from
   `apptest/chart/templates/tests.yaml`; keep the two in sync.

Two things to know before reproducing this locally — neither is a defect in the chart:

- **kind has no ingress controller**, so `status.loadBalancer.ingress` is never populated and
  `wait_for_ready.py` times out after 300s on `Ingress/<name> is not ready`. Install ingress-nginx,
  label the node `ingress-ready=true`, and give the controller
  `--watch-ingress-without-class=true --publish-status-address=127.0.0.1`.
- **The Ingress declares no `host`.** Under nginx a second install in the same cluster is rejected
  with `host "_" and path "/api" is already defined`. On GKE each Ingress gets its own load
  balancer, so this does not arise there — but delete a previous local install before re-running.

`mpdev` itself cannot parse a registry hostname containing a port (`localhost:5001` fails with
"Deployer image must have /deployer as the suffix", because it splits on `:`), and containerd
treats a dotless hostname as a Docker Hub namespace. A local registry therefore needs a dotted,
port-less alias such as `registry.kind.local`.

## Published images

Current release is **`1.0.5`** on track **`1.0`**, pushed 2026-10-09 to
`gcr.io/consiva-public/consiva-ai-kubernetes`. All six references carry
`com.googleapis.cloudmarketplace.product.service.name=services/consiva-ai-kubernetes.endpoints.consiva-public.cloud.goog`
on the **remote** manifest, each confirmed with `docker buildx imagetools inspect --raw`, and each
tag resolves to a single OCI manifest rather than an index.

| Image | Tags | Digest |
|---|---|---|
| `gcr.io/consiva-public/consiva-ai-kubernetes` (backend, **primary**) | `1.0`, `1.0.5` | `sha256:fbc4f3a2760f7b3d3f05b239cbae94a2533e1074e372db53251e409c1685ea07` |
| `…/consiva-ai-kubernetes/frontend` | `1.0`, `1.0.5` | `sha256:8f3f1f011d5f413f55e348ee099a492b744e4a84b2c30ba0fb1e215e501759c7` |
| `…/consiva-ai-kubernetes/deployer` | `1.0`, `1.0.5` | `sha256:a2e19fe506d1fd9b8169d65b08af52f58f1aae73d1d5a12543602bc294641d34` |

The frontend digest is unchanged since `1.0.2` — no frontend source has changed since.

**`1.0.0` through `1.0.5` are all spent.** Tags are never overwritten; the next rebuild needs
`1.0.6`. Superseded images remain in the registry and should not be used:

| Version | Why superseded |
|---|---|
| `1.0.0` | deployer schema unparseable (`sensitive` is not a v2 field) |
| `1.0.1` | frontend carries postcss CVE-2026-45623 |
| `1.0.2` | crash-loops when no database is reachable |
| `1.0.3` | starts without a database but never converges when one appears |
| `1.0.4` | ClusterIP Services rejected by GKE Ingress; backend could take longer than the readiness deadline to bind |

### Why 1.0.1 and 1.0.2 exist

**1.0.1 — schema.** Producer Portal rejected the `1.0.0` deployer outright:

```
Cannot find field: sensitive in message cloud.commerce.common.display.v1.XGoogleMarketplaceProperty
```

`sensitive: true` is **not** part of the v2 schema — the word appears nowhere in `schema.md`. The
correct declaration for a masked input is `type: MASKED_FIELD`. The `type: STRING` it was paired
with was inert as written: `STRING` only does anything alongside a `string:` block declaring
`generatedProperties`, and there was none.

The four secret inputs — `db.connectionString`, `jwt.secret`, `smtp.password` and
`enterpriseLicenseKey` — are now `MASKED_FIELD`. **This does not change how values reach the
chart.** `config_helper.py` treats `MASKED_FIELD` purely as a UI hint (it only asserts the
property is a string); no transformation is applied. Confirmed by reading the rendered Secret
after an install: the same four keys, with the connection string intact at full length including
its password and `IPAddressPreference=IPv4First` suffix.

**1.0.2 — CVE-2026-45623 (postcss).** Producer Portal's scan flagged postcss `8.4.31` in the
frontend image, fixed in `8.5.12`.

The vulnerable copy was **not** the project's own dependency. `package.json` declared postcss as a
devDependency and the lockfile resolved it to `8.5.28` — fine, and in any case absent from the
image, since a devDependency does not reach the `.next/standalone` output. The flagged copy was a
*nested* `node_modules/next/node_modules/postcss` at `8.4.31`, pinned as an exact dependency by
`next` 15.5.25, which does reach the image because the runtime stage copies `.next/standalone`.

The fix is an npm `overrides` entry forcing `postcss` to `^8.5.12` across the tree. npm rejects an
override that conflicts with a direct dependency range (`EOVERRIDE`), so the devDependency range
was raised from `^8.4.49` to `^8.5.12` to match — an explicit floor rather than an implicit one.
`next` itself was **not** bumped; nothing else in the tree changed.

Result, verified inside the built image rather than the working tree: exactly one postcss package,
at `8.5.29`, and no nested copy. The frontend still compiles (73/73 static pages) and serves —
`/` returns 307 to `/login`, and `/login` returns 200 with rendered HTML.

Worth knowing for the future: `next` ships many `postcss-*` packages under
`next/dist/compiled/`, but there is **no** precompiled bare `postcss` there, so an override does
reach the only copy that matters. Had there been one, an override would not have touched it.

Carrying *both* the track and version tag on the deployer is correct, not redundant.
`building-deployer.md` states each image "**must** carry the primary track ID and the specific
release version ID as its Docker tag", and its worked example shows the current deployer holding
both (`1.4`, `1.4.34`). A line in `building-deployer-helm.md` saying "the deployer excludes the
patch version in SemVer" contradicts that; the more specific page, which it links to for tag
rules, wins.

Deployer URL for Producer Portal, **no digest**:

```
gcr.io/consiva-public/consiva-ai-kubernetes/deployer
```

## Starting without a database, and the degraded state

Google verifies a Kubernetes app by deploying it unattended with whatever defaults `schema.yaml`
declares. This product deliberately ships no database, so there is nothing for those defaults to
point at. Until 1.0.3 the backend crash-looped in that situation and verification failed on an app
that is in fact correctly built.

From 1.0.3 the backend starts anyway when no database is reachable, and converges on its own once
one appears. The same thing covers the ordinary Kubernetes race where the app wins the start-up
race against its own database.

**One question decides which path is taken, and it is the only thing that does:** can a connection
be opened at all? If yes — the case on every AWS Marketplace deployment, where CloudFormation
creates the RDS instance alongside the container — everything runs inline exactly as it always
has, before traffic is served, and a seed that fails against a database that *is* there still
crashes the process. That behaviour is unchanged. If no, the app degrades instead.

### What distinguishes degraded from healthy

| Signal | Healthy | Degraded |
|---|---|---|
| `GET /health` status | 200 | **200 — unchanged** |
| `GET /health` body | `"status":"healthy"` | `"status":"degraded"`, plus `degradedSince` and `reason` |
| `GET /health/ready` | 200 | **503**, plus `failedAttempts` and `reason` |
| Logs | one startup line | `DEGRADED:` at Warning, repeated every 30s |

**The trade-off, stated rather than buried:** `/health` answers 200 forever even if the database
never appears, so a probe pointed only at `/health` cannot tell a working deployment from a
permanently broken one. That is the price of letting an unattended verification succeed instead of
crash-loop. The honest signal is `/health/ready`. The chart's own probes stay on `/health`
deliberately — a readiness probe on `/health/ready` would stop the pod ever becoming Ready during
verification, which is the exact failure this change exists to fix. **Point customer monitoring at
`/health/ready`.**

### What the degraded state actually costs

It is not a working deployment. The schema is not created, the Free plan and RBAC grants are not
seeded, and no recurring background job is registered. Registration and every permission-gated
action fail until a database appears. It serves, and it says loudly that it is not usable.

### Three things only the no-database test caught

All three compile cleanly and pass all 373 unit tests. Both mpdev scenarios pass with them
present, because neither exercises *recovery*.

1. **Hangfire killed startup, not the seeds.** `MigrateAsync` and the `DistributedCache` block were
   already wrapped in log-and-continue. The fatal call was
   `RecurringJobManager.AddOrUpdate` — Hangfire's storage *is* the database, so registering a
   schedule opens a connection and takes a distributed lock.
2. **The reachability probe could not see a server that lacked the app's database.** Connecting
   with `Database=CookieConsentDB` against a server that does not yet contain it is refused (SQL
   Server error 4060), so the probe reported "unreachable" forever and never reached
   `EnsureCreated` — the very thing that would create it. It now falls back to the login's default
   database.
3. **Hangfire's own tables were never installed on the degraded path.** `SqlServerStorage` creates
   them when first resolved from DI, which happens at startup — with the database down that
   silently did not happen, and convergence then failed with
   `Invalid object name 'HangFire.Hash'`. The convergence path now installs that schema explicitly.

Verified end to end on a local cluster: `/health/ready` 503 with no database, SQL Server scaled
from zero, 503 → 200 within ~30 seconds, **zero container restarts**, and the logs showing
`Hangfire schema ensured`, `Recurring background jobs registered`, `RECOVERED`.

## Why the primary image sits at the repository root

Marketplace requires the app's main image at the root of the image prefix. On a native Artifact
Registry path the prefix *is* the repository, and Artifact Registry rejects a manifest pushed
there — verified, it returns `400 Bad Request` on the manifest `PUT`, while the same image with one
extra path segment pushes fine. The `gcr.io` hostname is itself served by Artifact Registry,
mapping to a repository literally named `gcr.io` in location `us` of the project, so under `gcr.io`
the prefix is an ordinary image path and the main image can exist where Marketplace expects it.
Hence `gcr.io`, not `us-docker.pkg.dev`.

The backend is the primary image, declared under the `''` key in `schema.yaml`; the frontend is an
additional image in its own folder.

Google's own documents describe two different layouts, and both are legal:

- `create-app-package` says "Your app's main image must be in the root of the repository" — a
  primary image at the prefix, which is what this chart does.
- `building-deployer-helm.md` shows `gcr.io/your-company/wordpress/wordpress:9.0.3` alongside
  `…/deployer`, i.e. *named* images only and no primary at all.

`schema.md` settles it: "If your app contains a primary image, its repository must exactly match
the common prefix of the images." The "if" makes a primary image optional, and the tooling agrees
— `config_helper.py` reads it with `dictionary.get(...)`. Either shape is accepted, and mpdev
install + verify both pass against this one.

## Binding before database work

GKE validation rejected `1.0.4` with:

```
Readiness probe failed: dial tcp …:5000: connect: connection refused
ERROR Application did not get ready before timeout of 300.0 seconds
```

Connection *refused*, not a timeout — nothing was listening. `ASPNETCORE_URLS=http://+:5000` was
already set correctly in the backend Dockerfile, so this was not a misconfigured port: the process
simply had not reached Kestrel yet.

Everything that runs before the listener opens touches SQL Server — the schema check, the
`DistributedCache` table, Hangfire's storage. Each defaults to a 15-second connect timeout, and
both SqlClient and EF retry on top of that, so against an address with nothing behind it those
calls can hold startup for minutes. That is precisely the configuration Google verifies with,
because the schema's placeholder default points at `127.0.0.1`.

Three changes in `1.0.5`:

1. **Bind first.** `app.StartAsync()` now runs *before* any database work, then the database work
   runs, then `app.WaitForShutdownAsync()`. A probe gets a reply instead of a refused connection.
2. **Cap every startup connection.** `ConnectionStringTimeout.Cap(..., 5)` is applied to the
   schema check, the `DistributedCache` statement, Hangfire's storage, and the reachability probe.
3. **Drop EF's retry** on the schema check — it already tolerates failure, so retrying a dead
   address only delayed binding.

Measured under Google's exact conditions (schema defaults, no SQL Server anywhere):
**`/health` answers in 28 seconds.**

A consequence worth stating: with a reachable database the listener is now open during the few
seconds the seeds take, where previously the container accepted no connections at all. `/health`
answers 200 in that window; **`/health/ready` does not**, and it is the signal that gates real
traffic.

That test also exposed a flaw in the earlier work: the bootstrap state started *ready*, so for a
few seconds `/health` reported `"healthy"` and `/health/ready` returned 200 on a deployment that
had not yet checked whether it had a database. It now starts **pending** — `"degraded"` with
`"Startup bootstrap has not finished yet"` and a 503 — and resolves only once the probe answers.

## GKE Ingress: NodePort **and** the NEG annotation

GKE validation rejected `1.0.4` on all three tested versions (1.35.6, 1.35.8, 1.36.4):

```
Translation failed: invalid ingress spec: service "…-backend" is type "ClusterIP",
expected "NodePort" or "LoadBalancer" when not using NEGs
```

Both Services are now `NodePort` **and** carry `cloud.google.com/neg: '{"ingress": true}'`. Both
are needed, and the reason is in Google's own documentation
([GKE Ingress for Application Load Balancers](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/ingress)):

> For clusters where NEGs are not the default, it is still strongly recommended to use
> container-native load balancing, but it must be enabled explicitly on a per-Service basis.

GKE auto-enables container-native load balancing — and auto-adds that annotation — only when the
cluster is VPC-native, is not on a Shared VPC network, does not use GKE Network Policy, and has the
HttpLoadBalancing add-on enabled. The failure proves Google's verification clusters fail at least
one of those, so the annotation has to be stated rather than assumed.

The annotation alone is not enough either:

> If you use routes-based clusters with external Ingress, the GKE Ingress controller cannot use
> container-native load balancing using GCE_VM_IP_PORT NEGs. Instead, the Ingress controller uses
> unmanaged instance group backends that include all nodes in all node pools.

Instance group backends require `NodePort`. Nothing in the error says which case these clusters
are in, so the chart covers both: GKE uses NEGs where it can and instance groups where it cannot,
which is how GKE behaves natively — a Service may be `NodePort` and carry a NEG annotation at the
same time.

Nothing else is affected. `NodePort` is a superset of `ClusterIP`, so the cluster IP and in-cluster
DNS are unchanged, the apptest suite still resolves the Services by name, and non-GKE ingress
controllers are unaffected (they ignore the annotation). `service.type` remains a chart value, so a
customer can override it. The cost is a port in 30000–32767 on every node per Service; on GKE those
are not externally reachable without a firewall rule.

## Ingress: no host rule, deliberately

The Ingress declares no `host`. That is a decision, not an oversight:

- Google's packaging requirements say nothing requiring a host rule. They only "recommend
  configuring incoming connections using Istio Gateway, instead of LoadBalancer or Ingress
  resources" — a recommendation, and the requirement that actually binds is that resources are
  parameterized into the customer's chosen namespace, which this chart does.
- On GKE, where Marketplace customers deploy, each Ingress gets its own load balancer, so a
  host-less Ingress is fine and lets the customer reach the app on the load balancer address
  before they own a hostname.
- Under ingress-nginx, two installs in one cluster collide: the second is rejected with
  `host "_" and path "/api" is already defined`. Set `ingress.className` and give each install its
  own host if you need that, or disable the chart's Ingress with `ingress.enabled=false`.

Changing this would mean new images, new tags, a new deployer push and re-running mpdev, for no
requirement. Left as is.

## Outstanding manual steps

### 1. Secrets in `src/backend/CMP.API/appsettings.json` — done, no action

Scrubbed on 2026-10-05. Every Consiva-owned value in the base `appsettings.json` is now
`PLACEHOLDER_SET_VIA_ENV_VAR`, and the SaaS-only `appsettings.Production|Staging|Test|
Development.json` carry `PLACEHOLDER_NOT_USED_IN_CONTAINER_BUILD`. The keys themselves are all
still present, so configuration binding is unchanged. Details: `handoffs/SECRET_SCRUB_REPORT.md`.

The owner deliberately chose **not to rotate** the old values. That decision is recorded, not
pending — do not reopen it here. The one consequence that still matters: image layers are
immutable, so any image published before the scrub still contains the old values, and those
listing versions must be restricted or retired rather than "fixed".

Not overridden anywhere, and a real residual risk rather than a to-do for this folder:
`ConsentIntegrity.SigningKey` and `PiiSearchIndex.HashingKey` are the same placeholder on every
self-hosted deployment. Reported and deliberately left alone.

### 2. Service name and registry — done, no action

`build-images.sh` annotates every image with
`com.googleapis.cloudmarketplace.product.service.name=services/SERVICE_NAME`. Both the service
name and the registry now default to the real values, so the script needs no environment
override:

| Setting | Value |
|---|---|
| `SERVICE_NAME` | `consiva-ai-kubernetes.endpoints.consiva-public.cloud.goog` |
| `REGISTRY` | `gcr.io/consiva-public/consiva-ai-kubernetes` |

The old placeholder warning is replaced by a hard check that `SERVICE_NAME` ends in
`.cloud.goog`; a wrong value otherwise builds and pushes happily and is only rejected by
Marketplace much later, after the tags are spent.

**Why `gcr.io` and not `us-docker.pkg.dev`.** Marketplace requires the app's *main* image to sit
at the root of the image prefix. On a native Artifact Registry path the prefix *is* the
repository, and Artifact Registry rejects a manifest pushed there — verified, it returns
`400 Bad Request` on the manifest `PUT`. The `gcr.io` hostname is itself served by Artifact
Registry, mapping to a repository literally named `gcr.io` in location `us` of the project, so
under `gcr.io` the prefix is an ordinary image path and the main image can exist exactly where
Marketplace expects it. The published layout is therefore:

| Image | Reference |
|---|---|
| backend (**primary**) | `gcr.io/consiva-public/consiva-ai-kubernetes` |
| frontend | `gcr.io/consiva-public/consiva-ai-kubernetes/frontend` |
| deployer | `gcr.io/consiva-public/consiva-ai-kubernetes/deployer` |

Each is tagged with both the release track (`1.0`) and the version (`1.0.0`).

Note that `docker buildx --load` does **not** preserve manifest annotations — the annotation only
survives when the image is pushed as an OCI manifest. Verify on the **remote** reference:

```bash
docker buildx imagetools inspect gcr.io/consiva-public/consiva-ai-kubernetes:1.0.0 --raw   | grep -i service.name
```

### 3. Public Git repository — prepared, NOT published

Google requires the deployment configuration to live in a **public** Git repository containing a
LICENSE file and a user guide. Both are now written: `LICENSE` (Apache-2.0) and `USER_GUIDE.md`.

**Nothing has been published, and the repository has not been created.** That is the owner's to do.

Publish **only the contents of `deploy/gcp/`**. The repository this folder currently lives in is
private and holds the entire Consiva product, including application source; it must never be made
public. The files intended for the public repo are:

```
chart/            LICENSE           schema.yaml
apptest/          README.md         build-images.sh
deployer/         USER_GUIDE.md     tests/
consiva-logo.png
```

Do not publish anything from outside this folder.

### 4. Licence key generation tool

Built, and covered by its own handoff — see `tools/license-keygen/`.
`Enterprise:LicenseVerificationPublicKey` in `appsettings.json` now holds the **real** public key
(RSA-3072, RS256, kid `9112a851697c7a21`), baked into the image at build time. The same key serves
both AWS and GCP: `appsettings.SelfHosted.json` deliberately does not override it, and it is not a
Helm value — a customer-settable verification key would let a customer mint their own licences.
A licence that fails verification still logs a clear warning and falls back to Free.

### 5. Google Cloud project setup — partly done

APIs enabled on `consiva-public`:

| API | State |
|---|---|
| `artifactregistry.googleapis.com` | enabled 2026-10-07 |
| `containeranalysis.googleapis.com` | enabled 2026-10-07 — metadata storage only, it does **not** scan |
| `containerscanning.googleapis.com` | enabled 2026-10-08 — this is the one that actually scans |

The Marketplace page says "You must enable the Artifact Analysis API, which scans your container
images", and the submission review itself includes "scanning your containers for vulnerabilities
using Artifact Analysis". Scanning costs **$0.26 per image**, charged once when an image is first
pushed; roughly ₹70 for three images. Nothing was charged by enabling it, because scanning only
covers **newly pushed** images — the already-published `1.0.0` images are not scanned
retroactively. They will be scanned when `1.0.1` or later is pushed.

IAM grants required by *Setting up your Google Cloud environment*. Applied so far:

| Role | Principal | State |
|---|---|---|
| `roles/editor` | `group:cloud-commerce-marketplace-onboarding@twosync-src.google.com` | applied |
| `roles/servicemanagement.admin` | `group:cloud-commerce-marketplace-onboarding@twosync-src.google.com` | applied |
| `roles/servicemanagement.configEditor` | `serviceAccount:cloud-commerce-producer@system.gserviceaccount.com` | applied |
| `roles/servicemanagement.admin` | `serviceAccount:managed-services@cloud-marketplace.iam.gserviceaccount.com` | **OUTSTANDING** |
| `roles/servicemanagement.serviceConsumer` (service level) | `serviceAccount:cloud-commerce-procurement@system.gserviceaccount.com` | **OUTSTANDING** |
| `roles/servicemanagement.serviceController` (service level) | `serviceAccount:cloud-commerce-procurement@system.gserviceaccount.com` | **OUTSTANDING** |

Two corrections to the documented instructions, both found by running them:

1. **`roles/servicemanagement.serviceAdmin` does not exist.** `gcloud iam roles describe` returns
   "not found", and it is absent from `gcloud iam list-grantable-roles` for a project. The role
   *titled* "Service Management Administrator" — which is what the doc names — is
   `roles/servicemanagement.admin`. Use that.
2. **`cloud-commerce-marketplace-onboarding@twosync-src.google.com` is a group, not a service
   account.** The API rejects `serviceAccount:` for it and names the correct prefix: `group:`.

The project already carried `roles/servicemanagement.serviceController` and
`roles/serviceusage.serviceUsageConsumer` for `cloud-commerce-procurement@system.gserviceaccount.com`
at the **project** level before any of this work; they appear to come from listing creation. The
documented grants for that account are at the **service** level, where the policy is currently
empty.

Project Viewer on the registry project is not separately needed: the registry and the product are
both in `consiva-public`, and `roles/editor` there already subsumes Viewer.

### 6. Still blocking submission

- **`deploy-info` identifiers.** `chart/templates/application.yaml` still carries the unverified
  `{"partner_id": "consiva", "product_id": "consiva", …}`. Google's Helm deployer guide says these
  are fixed during onboarding and must match the listing; the owner is confirming them with the
  Partner Engineer rather than inferring them. The tooling only requires that both keys are
  *present* in the annotation (`validate_app_resource.py`), which is why mpdev passes with the
  current placeholder values — passing mpdev is **not** evidence that they are right.
  `x-google-marketplace.partnerId` / `solutionId` in `schema.yaml` are optional (`config_helper.py`
  reads them with `.get`), and are only cross-checked against the annotation when present. They are
  deliberately not declared, so there is one place to correct rather than two.
- **The three outstanding IAM grants above.**
- **Security contact** and the **Project Info form** — both named in the setup docs; the owner
  needs to confirm their state in the console.
