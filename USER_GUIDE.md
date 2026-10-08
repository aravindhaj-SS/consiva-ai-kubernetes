# Consiva.ai — Kubernetes deployment guide

Consiva.ai is a DPDP-compliant cookie and consent management platform. Deployed this way it runs
entirely inside your own cluster: consent records and data-principal requests never leave your
infrastructure, and the application makes no outbound call to Consiva at runtime.

This guide covers deploying from the command line with Helm. If you are deploying from the Google
Cloud Marketplace UI instead, the form collects the same values described under
[Configuration](#configuration) and you can skip to [Basic usage](#basic-usage).

---

## Overview

A deployment consists of one Pod with two containers, two Services, an Ingress, a ConfigMap, a
Secret, and an Application resource.

| Component | Purpose |
|---|---|
| `backend` container, port 5000 | REST API, consent storage, DSAR workflows, and the consent SDK served as a static file |
| `frontend` container, port 3000 | The administrator dashboard |
| `<name>-backend` Service, port 80 | Routes to the backend on 5000 |
| `<name>-frontend` Service, port 80 | Routes to the frontend on 3000 |
| Ingress | Path routing, below |
| ConfigMap | Non-secret configuration |
| Secret | Database connection string, JWT signing secret, SMTP password, licence key |

Both containers share one Pod deliberately. The frontend's API base URL is baked in at image
build time as `/` — an origin, not a path prefix — so it resolves against whatever origin served
the page, and the Ingress routes `/api/*` on that same host to the backend.

Ingress routing, in this order:

| Path | Match | Goes to |
|---|---|---|
| `/api` | Prefix | backend |
| `/sdk.js` | Exact | backend |
| `/sdk.min.js` | Exact | backend |
| `/` | Prefix | frontend |

`/sdk.js` and `/sdk.min.js` are the consent banner script that your own websites embed. They are
static files served by the backend, so they need their own rules — without them they fall through
to the frontend, which has no such file, and every embedding site gets a 404.

**Tiering.** With no licence key the deployment runs the Free tier. A signed Enterprise key issued
by Consiva unlocks the paid modules until the key's expiry date. The key is verified offline
inside your own cluster against a public key baked into the image; nothing is sent to Consiva or
to Google. A blank, invalid or expired key never blocks deployment — it simply runs Free and
records the reason in the backend's logs.

---

## One-time setup

You need:

- A Kubernetes cluster. GKE 1.21+ is the tested target.
- `kubectl`, configured against that cluster.
- `helm` 3.x.
- **A SQL Server database that the cluster can reach.** This application does **not** ship a
  database. Use Cloud SQL for SQL Server or your own instance, and create an empty database for
  it. The backend creates its own schema on first start.
- **An SMTP relay.** The backend refuses to start without one, by design: verification codes go
  to external data principals exercising their DPDP rights, and those people have no way to
  recover from a silently dropped message. Microsoft 365, Google Workspace and Amazon SES's SMTP
  interface all work.

Install the Application CRD, which the Application resource depends on. Skip this if your cluster
already has it — Marketplace clusters do.

```bash
kubectl apply -f \
  "https://raw.githubusercontent.com/GoogleCloudPlatform/marketplace-k8s-app-tools/master/crd/app-crd.yaml"
```

Create the namespace you intend to deploy into:

```bash
kubectl create namespace consiva
```

---

## Installation

```bash
helm install consiva ./chart \
  --namespace consiva \
  --set name=consiva \
  --set namespace=consiva \
  --set appDomainUrl="https://consent.example.com" \
  --set-string db.connectionString="Server=10.0.0.5,1433;Database=CookieConsentDB;User Id=consiva;Password=CHANGEME;TrustServerCertificate=True;Encrypt=True;IPAddressPreference=IPv4First;" \
  --set jwt.secret="$(openssl rand -base64 48)" \
  --set smtp.host=smtp.example.com \
  --set smtp.username=apikey \
  --set smtp.password=CHANGEME \
  --set smtp.fromEmail=no-reply@example.com
```

A connection string contains commas and semicolons, which `--set` interprets as value separators.
Either escape them, or — far easier — put your values in a file and use `-f`:

```bash
helm install consiva ./chart --namespace consiva -f my-values.yaml
```

`name` and `namespace` are passed as explicit values rather than inferred from the release,
because the Marketplace deployer supplies them that way and the templates read `.Values.name`
and `.Values.namespace` directly. Set them to match the release name and namespace you used.

### Configuration

| Value | Required | Default | Meaning |
|---|---|---|---|
| `name` | yes | `consiva` | Instance name. Prefixes every resource created. |
| `namespace` | yes | `default` | Namespace to deploy into. |
| `db.connectionString` | **yes** | empty | SQL Server connection string. Must include `;IPAddressPreference=IPv4First` — see below. |
| `jwt.secret` | **yes** | empty | Signs this deployment's own session tokens. Use a unique random value of at least 32 characters. Never reuse one across deployments. |
| `smtp.host` | **yes** | empty | SMTP server hostname. |
| `smtp.port` | no | `587` | `587` for STARTTLS, `465` for implicit TLS. |
| `smtp.username` | **yes** | empty | SMTP username. |
| `smtp.password` | **yes** | empty | SMTP password. Stored in the Secret. |
| `smtp.fromEmail` | **yes** | empty | Address outbound mail is sent as. |
| `smtp.fromName` | no | `Consiva CMP` | Display name on outbound mail. |
| `appDomainUrl` | no | `http://localhost` | The `https://` URL this deployment is reached at. Drives verification and password-reset links, the dashboard's CORS allowlist, and the embed snippet. |
| `enterpriseLicenseKey` | no | empty | Signed Enterprise licence key. Blank means Free tier. |
| `ingress.enabled` | no | `true` | Set `false` to manage ingress yourself. |
| `ingress.className` | no | empty | Set to your ingress class, e.g. `nginx`. Left empty, the cluster default applies — on GKE that is the GCE ingress controller. |
| `service.type` | no | `ClusterIP` | Service type for both Services. |
| `resources.backend` / `resources.frontend` | no | 500m/1Gi and 250m/512Mi requests | Container resource requests. |

**`IPAddressPreference=IPv4First` is not optional.** It works around a fault in
`Microsoft.Data.SqlClient` resolving IP addresses from Linux containers. Without it the backend
may fail to reach a database that is otherwise perfectly reachable.

`appDomainUrl` sets `App__FrontendBaseUrl`, `CdnBaseUrl` and `Cors__AllowedOrigins__0` to the same
value. That is deliberate: there is no separate CDN in this deployment model — one origin serves
the dashboard, the API and `/sdk.js`.

If you do not have a hostname yet, deploy once, take the Ingress address, then upgrade the release
with `appDomainUrl` set.

---

## Basic usage

Find the Ingress address:

```bash
kubectl get ingress consiva --namespace consiva
```

Check the backend is healthy. `/health` is a plain `200` with no authentication:

```bash
kubectl run check --rm -i --restart=Never --image=curlimages/curl:latest --namespace consiva \
  -- curl -s -o /dev/null -w '%{http_code}\n' \
  http://consiva-backend.consiva.svc.cluster.local/health
```

Expect `200`. The backend creates its schema on an empty database and registers background jobs
before it starts answering, so the first start takes appreciably longer than a warm one. The
readiness probe allows for this.

Open the Ingress address in a browser and register. **The first account created becomes the
administrator, and the deployment then locks to that single organization** — no second
organization can register afterwards.

Requesting `/` as an unauthenticated visitor returns a `307` redirect to `/login`. That is correct
behaviour, not a fault; if you put your own health check in front of this deployment, accept 3xx.

### TLS

The chart creates a plain Ingress with no TLS block. Terminate TLS the way your platform expects:
on GKE, attach a Google-managed certificate to the Ingress; with ingress-nginx, add a `tls:`
section and a certificate Secret. Set `appDomainUrl` to the `https://` URL once TLS is live, or
verification links will be emitted as `http://`.

### Embedding the consent banner

Once deployed, the dashboard's script modal gives you the snippet to paste into your own websites.
It points at `/sdk.js` on this deployment's own origin.

### Supplying or updating an Enterprise licence key

Keys are issued by Consiva after a BYOL contract. To apply or replace one:

```bash
helm upgrade consiva ./chart --namespace consiva --reuse-values \
  --set-string enterpriseLicenseKey="<the key>"
kubectl rollout restart deployment/consiva --namespace consiva
```

The key is read at startup and its expiry is re-checked on every tier decision, so a long-running
deployment drops to Free by itself when the term ends — no restart needed at expiry, and no data
is lost. To go back to Free deliberately, set `enterpriseLicenseKey=""` and restart.

The verification public key is baked into the image and is deliberately **not** a Helm value. A
customer-settable verification key would let anyone mint their own licences.

---

## Back up and restore

**All durable state is in your SQL Server database.** The containers hold no persistent data and
mount no volumes, so there is nothing to snapshot in the cluster. Back up and restore the database
using your normal tooling — Cloud SQL automated backups and point-in-time recovery, or your own
SQL Server backup schedule.

Keep a copy of the values you installed with, particularly `jwt.secret`. Restoring the database
against a deployment with a different `jwt.secret` invalidates every existing session; users will
simply have to sign in again, but it is avoidable.

---

## Image updates

Update to a newer patch or minor release by pointing the release at the new tags:

```bash
helm upgrade consiva ./chart --namespace consiva --reuse-values \
  --set image.backend.tag=<new-version> \
  --set image.frontend.tag=<new-version>
kubectl rollout status deployment/consiva --namespace consiva
```

Schema migrations run automatically at backend start. Back the database up first.

The deployment runs a single replica, so an upgrade involves a short interruption while the new
Pod starts and passes its readiness probe.

---

## Scaling

The chart deploys one replica, and **one replica is what this configuration is tested at**. Scale
vertically first, by raising the resource requests:

```bash
helm upgrade consiva ./chart --namespace consiva --reuse-values \
  --set resources.backend.requests.cpu=1 \
  --set resources.backend.requests.memory=2Gi
```

The two containers are co-located in a single Pod by design, so raising the replica count scales
the dashboard and the API together rather than independently. Background jobs are backed by
Hangfire's SQL Server storage, which coordinates scheduling across instances, so additional
replicas do not duplicate scheduled work. Session state is carried in signed tokens rather than
held in memory, so requests do not need to be pinned to a replica.

Even so, size the database for the added connections before scaling out, and contact Consiva
support if you intend to run multiple replicas in production — the combination is supported by
design but is not part of the tested configuration.

---

## Deletion

```bash
helm uninstall consiva --namespace consiva
kubectl delete namespace consiva
```

**Nothing deletes your data.** The database lives outside the cluster and is untouched by
uninstalling; drop it yourself when you are certain you no longer need it. DPDP record-keeping
obligations may require you to retain consent records after decommissioning the application — check
before dropping anything.

Nothing is intentionally orphaned in the cluster. Every resource the chart creates is owned by the
Application resource and is removed with the release. If you installed the Application CRD for this
app and use it for nothing else, remove it with
`kubectl delete crd applications.app.k8s.io` — but note this deletes Application resources for
every app in the cluster, so check first.

---

## Support

support@consiva.ai
