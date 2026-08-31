# Remote engine on Kubernetes

A remote engine scans a segment PQL itself cannot reach — a DMZ, a branch
network, a cloud VPC. It **dials out** to PQL and never accepts an inbound
connection from it, which is what makes it deployable behind a firewall that
would refuse one.

This is not the PQL application. Install [`../pql`](../pql/README.md) wherever
PQL lives; install this in the segment.

```bash
kubectl create secret generic pql-engine-token \
  --from-literal=PQL_ENGINE_TOKEN='<issued in Settings → Remote engines>'

helm install engine deploy/helm/pql-remote-engine -n pql-engine --create-namespace \
  --set serverUrl=https://pql.example.com \
  --set existingSecret=pql-engine-token \
  --set engineName=dmz-frankfurt
```

The engine runs its own preflight at startup and names the step that failed:

```
preflight resolve  ok   pql.example.com resolves
preflight connect  ok   pql.example.com:443 accepts
preflight tls      ok   certificate verified
preflight token    ok
```

## What the chart refuses

- **`serverUrl` over `http://`.** The engine token travels on every request, so
  cleartext hands it to anything on the path. Refused rather than warned about:
  an engine is deployed once into a segment nobody revisits, so an install-time
  warning is read by nobody a year later. Use `https://`, with
  `caBundle.configMap` if PQL serves a private CA.
- **A token as a values field.** It authenticates this engine for as long as it
  is valid; a value lands in `helm get values` and in every CI log that renders
  the chart. `existingSecret` only.
- **A relay port with no `relay.publicName`.** The relay hands scanning hosts an
  address to dial back on. That address is `publicName`, not the Service name —
  those hosts are outside the cluster and cannot resolve cluster DNS. Without it
  they are handed something that does not answer.
- `serverUrl` with no scheme, and an unknown `autoUpdate` value.

## Updates

`autoUpdate` is `notify` by default: PQL says a newer build exists and nothing
moves. `auto` makes the engine **exit** when one is advertised, so the kubelet
replaces it — and the chart then sets `imagePullPolicy: Always` for you, because
without it the engine restarts onto the same image, finds itself stale, and
exits again. That crash-loop reads as a broken engine rather than a missing pull
policy.

Decide it deliberately. These containers sit where nobody has a shell.

`PQL_ENGINE_PLATFORM` is stated as `kubernetes` rather than left to
autodetection. The engine can infer it from `KUBERNETES_SERVICE_HOST`, which is
real but circumstantial — a sidecar-injecting mesh or a bare `kubectl run` can
make it lie — and the platform decides what an update actually does.

## One engine per token

`replicas` is not a value. The token names one engine in PQL's console; a second
Pod sharing it is the same engine claiming work twice, sending two heartbeats
and reporting two versions. For more capacity, issue another token and install
this chart again under a different release name.

## Verified

Against a live PQL on a kind cluster, 2026-08-31: the engine started from this
chart's rendered Deployment, resolved and connected to PQL over TLS with a CA
bundle mounted from `caBundle.configMap`, verified the certificate, and was
refused with a 401 on a deliberately invalid token — which is the whole wiring
proven, with the only failure being the one that was engineered.

Not yet verified: a real scan through an engine deployed this way, and the relay
listener.
