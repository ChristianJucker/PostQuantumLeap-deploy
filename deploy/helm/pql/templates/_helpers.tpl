{{/*
Names, labels, and — the part worth reading — the validation that runs before
anything renders. Every `fail` here is a misconfiguration that would otherwise
install cleanly and be wrong silently.
*/}}

{{- define "pql.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "pql.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "pql.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "pql.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "pql.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "pql.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pql.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "pql.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ $tag }}
{{- end -}}
{{- end -}}

{{/* The Secret the workload reads from. */}}
{{- define "pql.secretName" -}}
{{- if .Values.existingSecret -}}
{{ .Values.existingSecret }}
{{- else -}}
{{ include "pql.fullname" . }}-generated
{{- end -}}
{{- end -}}

{{- define "pql.dbHost" -}}
{{- if .Values.postgresql.enabled -}}
{{ include "pql.fullname" . }}-db
{{- else -}}
{{ .Values.externalDatabase.host }}
{{- end -}}
{{- end -}}

{{/*
The trusted-proxy CIDR list the app is given.

In `sidecar` mode this is loopback and nothing else: the proxy is a container in
the same Pod, so it speaks from 127.0.0.1 and there is no dynamic pod IP to
guess at. This is the whole reason the proxy is a sidecar rather than its own
Deployment — see templates/deployment.yaml.
*/}}
{{- define "pql.trustedProxyCIDRs" -}}
{{- if eq .Values.ingress.mode "sidecar" -}}
127.0.0.1/32
{{- else -}}
{{ join "," .Values.ingress.trustedProxyCIDRs }}
{{- end -}}
{{- end -}}


{{/*
The engine-images data image.

⚠ ITS TAG IS AN ENGINE VERSION, NOT AN APPLICATION ONE, and it is NOT hardcoded
here. A literal in a template is a second copy of a number that lives in
`backend/app/version.py`, and the remote-engine chart already shipped that exact
bug once — `appVersion: 1.1.0` against a server advertising 1.3.0, every engine
stale from its first heartbeat. The value lives in values.yaml, where a test
pins it to ENGINE_VERSION.
*/}}
{{- define "pql.engineImagesImage" -}}
{{- $tag := .Values.engineImages.image.tag -}}
{{- if and (not $tag) (not .Values.engineImages.image.digest) -}}
{{- fail "engineImages.image.tag is empty and no digest is set — the chart will not guess which engine build to serve" -}}
{{- end -}}
{{- if .Values.engineImages.image.digest -}}
{{ .Values.engineImages.image.repository }}@{{ .Values.engineImages.image.digest }}
{{- else -}}
{{ .Values.engineImages.image.repository }}:{{ $tag }}
{{- end -}}
{{- end -}}

{{/*
──────────────────────────────────────────────────────────────────────────────
VALIDATION. Included once from deployment.yaml so it runs on every render,
including `helm template` and `helm lint`.
──────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "pql.validate" -}}

{{- if not (has .Values.ingress.mode (list "sidecar" "external")) -}}
{{- fail (printf "ingress.mode must be 'sidecar' or 'external', got %q" .Values.ingress.mode) -}}
{{- end -}}

{{/* ── secrets ────────────────────────────────────────────────────────── */}}
{{- if and (not .Values.existingSecret) (not .Values.eval.generateSecrets) -}}
{{- fail "\n\nexistingSecret is not set.\n\nThe chart does not generate secrets: SETTINGS_ENC_KEY protects stored SSO client\nsecrets, and the usual `randAlphaNum` + `lookup` idiom silently regenerates it\nunder `helm template` — which is how ArgoCD and Flux render charts — making every\nstored secret undecryptable.\n\nCreate the Secret yourself, or sync it from a vault with external-secrets:\n  docs/deploy/secret-injection.md\n\nRequired keys: POSTGRES_PASSWORD, APP_DB_PASSWORD, SESSION_SECRET_KEY,\nSETTINGS_ENC_KEY, INITIAL_ADMIN_USERNAME, INITIAL_ADMIN_PASSWORD.\n\nFor a local evaluation cluster only:\n  --set eval.generateSecrets=true --set eval.acknowledgeEphemeral=true\n" -}}
{{- end -}}

{{- if and .Values.eval.generateSecrets (not .Values.eval.acknowledgeEphemeral) -}}
{{- fail "\n\neval.generateSecrets is on but eval.acknowledgeEphemeral is not.\n\nGenerated secrets are preserved across upgrades by `lookup`, which returns EMPTY\nunder `helm template`. Rendering this release through ArgoCD, Flux, or any\n`helm template | kubectl apply` pipeline will rotate SETTINGS_ENC_KEY and make\nevery stored SSO client secret undecryptable.\n\nThis is data loss, not an outage, which is why it needs a second flag:\n  --set eval.acknowledgeEphemeral=true\n" -}}
{{- end -}}

{{/* ── the proxy trust configuration, in `external` mode ──────────────── */}}
{{- if eq .Values.ingress.mode "external" -}}

  {{- if not .Values.ingress.trustedProxyCIDRs -}}
  {{- fail "\n\ningress.mode is 'external' but ingress.trustedProxyCIDRs is empty.\n\nPQL must know which addresses your ingress controller speaks from, or it cannot\ntell a forwarded client address from one a client made up. With the list empty\nthe app degrades every client behind the proxy into ONE shared rate-limit\nbucket — it fails closed, but your login rate limiting and account lockout stop\ndistinguishing between attackers.\n\nFind your controller's pod addresses:\n  kubectl -n ingress-nginx get pods -o jsonpath='{.items[*].status.podIP}'\n\nThen set, for example:\n  --set ingress.trustedProxyCIDRs={10.42.1.0/24}\n\n`helm test` verifies the result end to end after install.\n" -}}
  {{- end -}}

  {{- range .Values.ingress.trustedProxyCIDRs -}}
    {{- $cidr := . -}}
    {{- $parts := splitList "/" $cidr -}}
    {{- if ne (len $parts) 2 -}}
    {{- fail (printf "ingress.trustedProxyCIDRs entry %q is not a CIDR — it needs a prefix length, e.g. 10.42.1.7/32 for a single address" $cidr) -}}
    {{- end -}}
    {{- $prefix := atoi (index $parts 1) -}}
    {{/*
      A /16 floor. This is not arithmetic pedantry: TRUSTED_PROXY_CIDRS used to
      default to 172.16.0.0/12 — the whole Docker bridge space — and any caller
      that reached the host was observed as an address inside it, passed the
      speaker check, and got to write the entire X-Forwarded-For chain the login
      rate limiter keys on. A range wide enough to contain workloads you did not
      put there is not "the proxy"; it is the range the proxy happens to sit in.
    */}}
    {{- if lt $prefix 16 -}}
    {{- fail (printf "\n\ningress.trustedProxyCIDRs entry %q is a /%d, which is too broad to be a proxy.\n\nEverything inside this range is trusted to declare the client address that PQL\nrate-limits and locks out on. At /%d that is a range wide enough to hold\nworkloads you did not put there — any one of which could then choose which\nbucket it lands in, or which account gets locked.\n\nThis is the shape of the 172.16.0.0/12 default that was removed from\ndocker-compose.yml on 2026-08-24 for exactly this reason.\n\nName the controller's own addresses (a /32 per pod, or the /24 its pool sits\nin), not the network they are reachable from.\n" $cidr $prefix $prefix) -}}
    {{- end -}}
  {{- end -}}

  {{- if .Values.service.exposeAppPort -}}
  {{- fail "\n\nservice.exposeAppPort is on in 'external' mode.\n\nThat publishes the app's own port 8000 alongside your ingress, so anything that\ncan reach the Service bypasses the proxy entirely — and a request that did not\ncome through the proxy carries no trustworthy forwarded chain. The app will log\n\"the app port is reachable off-proxy or the CIDR set is wrong\" and it will be\nright.\n\nLeave it off unless you are wiring an e2e harness, and never in this mode.\n" -}}
  {{- end -}}

{{- end -}}

{{/* ── hosted engine images ────────────────────────────────────────────── */}}
{{- if not (has .Values.engineImages.source (list "none" "image" "existingClaim")) -}}
{{- fail (printf "engineImages.source must be none, image or existingClaim, got %q" .Values.engineImages.source) -}}
{{- end -}}
{{- if and (eq .Values.engineImages.source "existingClaim") (not .Values.engineImages.existingClaim) -}}
{{- fail "\n\nengineImages.source is 'existingClaim' but engineImages.existingClaim is empty.\n\nName the PersistentVolumeClaim holding your engine tarballs, or use\n`source: image` to have an init container stage them from an OCI image.\n" -}}
{{- end -}}
{{- if and (eq .Values.engineImages.source "image") (not .Values.engineImages.image.repository) -}}
{{- fail "\n\nengineImages.source is 'image' but engineImages.image.repository is empty.\n\nBuild one from your staged tarballs:\n  ./scripts/build-engine-images-image.sh --push\n" -}}
{{- end -}}

{{/* ── database ───────────────────────────────────────────────────────── */}}
{{- if and (not .Values.postgresql.enabled) (not .Values.externalDatabase.host) -}}
{{- fail "\n\nNo database configured. Set externalDatabase.host to a managed Postgres, or\nturn on the bundled one for an evaluation cluster:\n  --set postgresql.enabled=true\n\nThe bundled StatefulSet has no backup, no failover and no pooling. It is not a\nsupported production database.\n" -}}
{{- end -}}

{{- end -}}
