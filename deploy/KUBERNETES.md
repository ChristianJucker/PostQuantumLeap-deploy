# Post Quantum Leap on Kubernetes

A Helm chart for running PQL on your own cluster. It deploys the application,
optionally a TLS terminator, and — importantly — a test that proves your ingress
is wired correctly before you rely on it.

> **Docker Compose is the simpler path** and remains fully supported. Use
> Kubernetes when you already run one: the chart gives you no capability compose
> lacks, and PQL runs as a single replica either way.

## Requirements

- Kubernetes 1.27 or newer, and Helm 3.12+
- A PostgreSQL 16 database (managed is strongly recommended)
- A Kubernetes `Secret` holding six values, described below
- 1 GB of memory and ~2 GB of storage for the application

## 1. Create the Secret

**The chart does not generate secrets, deliberately.** `SETTINGS_ENC_KEY` is the
key that protects stored SSO client secrets, and Helm's usual "generate once,
keep forever" idiom silently mints a new one when the chart is rendered by
ArgoCD, Flux, or any `helm template` pipeline. A rotated key makes every stored
secret undecryptable — data loss, not an outage. So you own these values.

```bash
kubectl create namespace pql

kubectl -n pql create secret generic pql-secrets \
  --from-literal=POSTGRES_PASSWORD='<owner role password>' \
  --from-literal=APP_DB_PASSWORD='<runtime role password>' \
  --from-literal=SESSION_SECRET_KEY="$(openssl rand -base64 48)" \
  --from-literal=SETTINGS_ENC_KEY="$(python3 -c 'import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())')" \
  --from-literal=INITIAL_ADMIN_USERNAME='admin@example.com' \
  --from-literal=INITIAL_ADMIN_PASSWORD='<first login password>'
```

`SETTINGS_ENC_KEY` must be url-safe base64 of exactly 32 bytes — the command
above produces one. `SESSION_SECRET_KEY` must be at least 32 characters.
`INITIAL_ADMIN_USERNAME` must be an e-mail address; nothing is ever mailed to
it.

**Back up `SETTINGS_ENC_KEY` somewhere you will still have it in a year.**
Losing it does not lock you out of PQL, but any SSO client secrets stored in the
database become unreadable.

If you run [external-secrets](https://external-secrets.io/) or the Secrets Store
CSI driver, sync these six keys into a `Secret` of the same shape instead and
point `existingSecret` at it.

## 2. Choose how TLS reaches the pod

### `sidecar` — the bundled proxy (default)

Caddy runs alongside the application inside the same pod and terminates TLS.
Nothing about client-address trust is yours to configure: the proxy is on
loopback and the chart pins it there.

```bash
helm install pql ./deploy/helm/pql -n pql \
  --set existingSecret=pql-secrets \
  --set externalDatabase.host=postgres.example.internal \
  --set service.type=LoadBalancer \
  --set tls.acmeDomain=pql.example.com \
  --set tls.acmeEmail=ops@example.com
```

With `tls.acmeDomain` set and no TLS configuration in the database yet, the
instance starts in ACME mode and orders its own certificate.

### `external` — your ingress controller

You terminate TLS at your edge. **You must tell PQL which addresses your
controller speaks from.**

```bash
kubectl -n ingress-nginx get pods -o jsonpath='{.items[*].status.podIP}'
```

```bash
helm install pql ./deploy/helm/pql -n pql \
  --set existingSecret=pql-secrets \
  --set externalDatabase.host=postgres.example.internal \
  --set ingress.mode=external \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set ingress.host=pql.example.com \
  --set 'ingress.trustedProxyCIDRs={10.42.1.0/24}' \
  --set ingress.preflightAddress=ingress-nginx-controller.ingress-nginx.svc.cluster.local
```

`ingress.trustedProxyCIDRs` has no default and the chart refuses to install
without it. It is a **security** setting, not a connectivity one:

- **too narrow** — every client behind your proxy shares one login rate-limit
  and lockout bucket, so throttling can no longer tell two callers apart;
- **too broad** — anything that can reach the application port can claim to be
  any client address, and choose whose bucket it lands in.

Name the controller's own addresses — a `/32` per pod, or the `/24` its pool
sits in — not the network they happen to be reachable from. The chart rejects
anything wider than a `/16`.

`ingress.trustedProxyHops` counts proxies from the right of `X-Forwarded-For`:
one ingress controller is `1`, a CDN in front of it is `2`.

## 3. Verify it — this step is not optional

```bash
helm test pql -n pql --logs
```

```
OK: chain verified. PQL attributed this request to 203.0.113.44,
    which means per-client rate limiting and lockout are working as
    intended behind your proxy.
```

This sends a real request through your ingress and asks the running
installation what client address it believed. A wrong `trustedProxyCIDRs`
produces no error anywhere else — not in `kubectl get`, not in a dashboard, and
not reliably in the logs — so this is the only thing that will tell you.

Re-run it after any change to your ingress, your controller's addresses, or the
number of proxies in front of PQL.

If it cannot reach your host name from inside the cluster, set
`ingress.preflightAddress` to your controller's in-cluster Service as shown
above; the test then dials the controller directly and carries your public host
name in the `Host` header, so the ingress is still in the path.

## 4. Sign in

Use the address you put in `INITIAL_ADMIN_USERNAME`. The first login forces a
password change.

## What this deployment does not do

**There is no high availability, and `replicas` is not configurable.** PQL runs
as one replica with a `Recreate` update strategy, because the scan scheduler
runs inside the application process, database migrations run at startup, and the
certificate volume cannot be attached twice. A second replica would double every
scheduled scan and race the migration. Plan for a short gap during upgrades.

**The bundled PostgreSQL is for evaluation only.** `--set postgresql.enabled=true`
brings up a single-instance database with no backup, no failover and no
connection pooling. It exists so a fresh cluster comes up with no other
prerequisite. Point `externalDatabase.host` at a real database before the data
matters.

**Hosted remote-engine images need one extra step**, and only if you want them —
see below. Most installations upload an engine archive through the platform
console and need nothing here.

## Scanning a segment PQL cannot reach

A **remote engine** runs inside another network — a DMZ, a branch, a cloud VPC —
and dials out to PQL. It has its own chart:

```bash
kubectl create secret generic pql-engine-token \
  --from-literal=PQL_ENGINE_TOKEN='<issued in Settings → Remote engines>'

helm install engine ./deploy/helm/pql-remote-engine -n pql-engine --create-namespace \
  --set serverUrl=https://pql.example.com \
  --set existingSecret=pql-engine-token \
  --set engineName=dmz-frankfurt
```

It prints its own preflight at startup and names the step that failed —
resolve, connect, TLS, token. Behind a private CA, pass the bundle with
`--set caBundle.configMap=<name>`.

Engines do not update themselves by default: PQL reports that a newer build
exists and you redeploy when ready. See that chart's README before changing
`autoUpdate`.

### Serving the engine archive from an air-gapped segment

An engine is often deployed on a host chosen precisely because it has no route
to a registry, so PQL can serve the engine's `docker save` archive for you to
`docker load` there. Upload one through the platform console and you are done.

If the segment cannot reach the console either — you mirror everything into your
own registry — the chart can carry the archives instead:

```bash
helm upgrade pql ./deploy/helm/pql -n pql --reuse-values \
  --set engineImages.source=image \
  --set engineImages.image.repository=registry.example.com/pql-engine-images \
  --set engineImages.image.tag=1.3.0
```

An init container copies the archives out of that image at startup and PQL seeds
them into its database. The tag is an **engine** version and must match the build
your PQL advertises, or it will serve an archive it then reports as stale.

Already have the archives on a volume? Point at it instead and skip the image:

```bash
--set engineImages.source=existingClaim --set engineImages.existingClaim=<pvc>
```

Either way this is optional. Left alone, nothing is broken — PQL simply has no
hosted archive until someone uploads one.

## Upgrading

```bash
helm upgrade pql ./deploy/helm/pql -n pql --reuse-values --set image.tag=<version>
```

Migrations run automatically at startup. Take a database backup first; there is
no automatic rollback of a schema change.

## Common problems

**`502` from your ingress, and it returns after every restart.** The
application pushes its own proxy configuration at startup. In `sidecar` mode the
chart handles this; if you have overridden `PROXY_UPSTREAM`, set it back.

**`helm test` says `attributable: false`.** Your `trustedProxyCIDRs` does not
contain the address your controller speaks from, or `trustedProxyHops` does not
match your real chain. The test output prints the number of `X-Forwarded-For`
entries it saw — compare that with your hop count. The application log names the
address it refused:

```bash
kubectl -n pql logs deploy/pql-pql -c app | grep -i forwarded
```

**`helm test` reports a 404.** The application image predates the check. Upgrade
to a release that includes it.

**The pod stays in `Init` for a long time.** It is waiting for the database.
Confirm the host, port and credentials in your Secret, and that the cluster can
reach it.

**First startup takes several minutes.** A new database runs the full migration
history before the application accepts connections. The startup probe allows
five minutes.

## Uninstalling

```bash
helm uninstall pql -n pql
```

Persistent volume claims are **not** removed with the release. Delete them
explicitly once you are sure:

```bash
kubectl -n pql delete pvc --all
```
