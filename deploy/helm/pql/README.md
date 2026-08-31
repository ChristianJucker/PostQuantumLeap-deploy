# PQL on Kubernetes

A deliberately small chart. It owns the workload, the environment contract, and
the *validation* of your proxy trust configuration. It does not own your ingress
controller, your certificates, your storage class or your database — and where
it cannot check something, it refuses to guess rather than defaulting.

**Status: works, and every claim below was measured on a `kind` cluster. Not yet
released.** No CI job renders it, and the app image carrying the one endpoint
`helm test` needs is not published.

## Install

```bash
helm install pql deploy/helm/pql -n pql --create-namespace \
  --set existingSecret=pql-secrets \
  --set externalDatabase.host=pg.example.internal
```

Then, and this is not optional:

```bash
helm test pql -n pql --logs
```

## The two modes

| | `sidecar` (default) | `external` |
|---|---|---|
| TLS terminates | in the Pod, by Caddy | at your ingress controller |
| `TRUSTED_PROXY_CIDRS` | `127.0.0.1/32`, by construction | **you must supply it** |
| Containers in the Pod | app + caddy | app |
| Service | 443 | 8000 |
| What can go wrong | very little | the trust configuration, silently |

### Why the proxy is a sidecar

A literal translation of `docker-compose.yml` — one Deployment per service —
breaks three things at once. Co-locating them fixes all three:

1. **`TRUSTED_PROXY_CIDRS=172.28.0.10/32` in compose is a *static* proxy
   address.** Pod IPs are dynamic, and trusting the pod CIDR instead re-opens
   exactly the forgeable-`X-Forwarded-For` hole that the fixed subnet was
   introduced to close on 2026-08-24. As a sidecar the proxy is loopback.
2. **The TLS volume is `rw` in app and `ro` in caddy** — the app writes key
   material Caddy loads. Two Pods sharing a volume needs ReadWriteMany, which no
   default StorageClass provides. One Pod makes ReadWriteOnce correct.
3. **The app pushes Caddy's config over the admin API.** Same Pod means
   localhost, and the admin listener never leaves the Pod's network namespace.

## `helm test` is the point of this chart

`ingress.trustedProxyCIDRs` is a security control that fails **silently in both
directions**:

- **too narrow** → every client behind your proxy shares one rate-limit and
  lockout bucket, so login throttling stops telling callers apart;
- **too broad** → anything that can reach the app port forges the chain and
  chooses which bucket it lands in, or which account gets locked.

Neither appears in `kubectl get`, in a dashboard, or in any log you would think
to check. So the chart does not ask you to get it right from a values file — it
asks the running installation what it actually believed, through the same path a
real user takes:

```
OK: chain verified. PQL attributed this request to 10.244.0.40,
    which means per-client rate limiting and lockout are working as
    intended behind your proxy.
```

Measured behaviour of the cases that matter:

| Configuration | Result |
|---|---|
| sidecar, correct | passes, attributes the caller's own address |
| sidecar, `TRUSTED_PROXY_CIDRS` pointed at a network the proxy is not in | **fails**, and the message names the log line that shows the real address |
| external through ingress-nginx, correct CIDR | passes |
| external, plausible-but-wrong CIDR (`10.99.0.0/24`) | **fails** |
| external, correct CIDR but `trustedProxyHops: 2` | **fails**, and prints `entries seen: 1` against `hops: 2` |

### `ingress.preflightAddress`

In `external` mode the preflight must reach PQL *through* your controller.
Dialling the public host name from inside the cluster only works where the
cluster's resolver knows it — with a split-horizon zone or a private name it
fails with `Name or service not known` and tells you nothing. Set this to the
controller's in-cluster Service and the preflight dials that, carrying
`ingress.host` in the `Host` header, so nginx matches the same rule a real
request would:

```yaml
ingress:
  preflightAddress: ingress-nginx-controller.ingress-nginx.svc.cluster.local
```

## Secrets: the chart does not generate them

`SETTINGS_ENC_KEY` is the Fernet key protecting stored SSO client secrets. The
usual Helm idiom for "generate once, keep forever" is `randAlphaNum` guarded by
a `lookup` of the existing Secret — **and `lookup` returns empty under
`helm template`**, which is how ArgoCD, Flux and every
`helm template | kubectl apply` pipeline render a chart.

Measured on the same release:

```
SETTINGS_ENC_KEY now:            OE5YdjJrTk1oUVBUNHI5ZHU3...
after in-cluster helm upgrade:   OE5YdjJrTk1oUVBUNHI5ZHU3...   → preserved
helm template produced:          SHJzU2s0VnFYWHBNTkY4bkVD...   → different key
```

A different key means every stored SSO client secret is undecryptable. That is
data loss, not an outage, so the supported path is a Secret you control — create
it yourself or sync it from a vault with `external-secrets`; see
[`docs/deploy/secret-injection.md`](../../../docs/deploy/secret-injection.md).

`eval.generateSecrets=true` exists for a local cluster and needs
`eval.acknowledgeEphemeral=true` alongside it, because the failure mode is
silent data loss rather than an error.

## What the chart refuses to install

Each of these fails at render time with an explanation, not at 3am:

- no `existingSecret` and no acknowledged `eval.generateSecrets`
- `eval.generateSecrets` without `eval.acknowledgeEphemeral`
- no database at all
- `ingress.mode: external` with no `trustedProxyCIDRs`
- a CIDR shorter than `/16`, or `0.0.0.0/0` — a range wide enough to contain
  workloads you did not put there is not "the proxy"
- an entry with no prefix length
- `service.exposeAppPort` in `external` mode, which would let callers bypass
  the ingress entirely
- `ingress.enabled` in `sidecar` mode, which would be a second TLS terminator

## There is no HA

One replica, `strategy: Recreate`, ReadWriteOnce volumes. Three independent
reasons, any one sufficient: APScheduler runs **in-process**, so a second replica
fires every tenant's scheduled scan twice; `entrypoint.sh` runs
`alembic upgrade head` on boot, so two replicas race the migration; and the TLS
PVC cannot attach twice. `replicas` is not a value, and the chart does not
pretend otherwise. Plan maintenance windows accordingly.

## The environment contract

Every variable the app receives is declared in one place,
[`templates/_env.tpl`](templates/_env.tpl), and
`backend/tests/test_helm_chart_env_contract.py` asserts that the set matches what
the application actually reads — from `Settings` **and** from direct `os.environ`
access — or carries a written reason for the difference.

This guards the bug class compose shipped twice: `ENGINE_VERSION` was read by the
app, documented in INSTALLATION.md, and never listed in compose, so the
fleet-wide engine rollback lever could not be pulled at all, with no error to say
why. The same happened to the whole `SCAN_*` group.

The test is mutation-checked: deleting any of `ENGINE_VERSION`,
`SCAN_CONCURRENCY`, `TRUSTED_PROXY_CIDRS` or `REMOTE_ENGINE_LEASE_SECONDS` from
`_env.tpl` fails it. An earlier version scanned only `Settings` and **passed**
with `ENGINE_VERSION` deleted — because that variable lives in the `os.environ`
half. Registries need mutating before they can be believed.

`extraEnv` is additive only: Kubernetes rejects duplicate env names on a
container, so an entry colliding with a charted name fails the whole Deployment
rather than overriding it.

## The NetworkPolicy, and the two bugs verifying it found

Running the policy under a CNI that enforces (Calico on kind, 2026-08-31) broke
it twice — neither failure was visible on kindnet, which accepts policies and
ignores them:

1. **It blocked the application in `sidecar` mode.** The ingress rule named
   `networkPolicy.ingressNamespace`, which only makes sense when an ingress
   controller exists. In sidecar mode clients arrive through a LoadBalancer,
   NodePort or port-forward, so every path was denied — including the chart's
   own `helm test`, which timed out after seven attempts.
2. **It left the bundled database wide open.** The policy selected the
   application pods and nothing selected the database, so any pod in the
   namespace could open 5432 — measured with a throwaway busybox. Compose binds
   that database to `127.0.0.1` for exactly this reason; a StatefulSet has no
   equivalent, so the restriction only exists if it is written.

Both fixed and re-measured, in both modes:

| Probe | sidecar | external |
|---|---|---|
| app TLS port 443 from any pod | reachable | n/a |
| app port 8000 from a random pod | n/a | **blocked** |
| app port 8000 from the ingress controller | n/a | reachable |
| database 5432 from a random pod | **blocked** | **blocked** |
| `helm test` | passes | passes |

## Local cluster

```bash
kind create cluster --config ../../kubernetes/kind-config.yaml
```

**`kind load docker-image` does not work against Docker Desktop's containerd
image store** — every image fails with `content digest sha256:…: not found`,
because `docker save` emits a manifest list whose non-native platform has no
local blobs and kind imports with `--all-platforms`. Dropping that one flag
works:

```bash
docker save <image> | docker exec --privileged -i pql-control-plane ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs -
```

## Known gaps

- **The app image must carry `/api/health/forwarded`.** That one endpoint is
  added alongside this chart; against an older image the preflight says so and
  exits rather than failing obscurely. The probes need nothing: they are
  `tcpSocket`, which is exact here because `entrypoint.sh` opens the port only
  after `alembic upgrade head` returns.
- **Hosted remote-engine images are supported** (`engineImages.source`), by an
  init container staging them out of a data image, or by a PVC you populate.
  Both were verified end to end: the archive reaches the pod and PQL writes the
  `remote_engine_images` row. Off by default, and off is right for anyone who can
  reach the console — `ensure_seeded_images` returns 0 when the directory is
  absent, so leaving it alone breaks nothing.
- **No CI.** Nothing renders or installs this chart automatically yet.
- **Single-node testing only.** Nothing here proves ReadWriteOnce behaviour
  across nodes; the sidecar exists partly so that question never arises.
- **NetworkPolicy is off by default**, because enforcement is CNI-dependent:
  kindnet accepts a policy, shows it in `kubectl get`, and enforces nothing —
  a deny-all egress policy there let a probe reach `1.1.1.1:53` unimpeded.
  Turn it on where your CNI enforces, and prove it with a deny-all probe first.
  It is now VERIFIED under Calico (see below), so the default is caution about
  your cluster rather than doubt about the template.
