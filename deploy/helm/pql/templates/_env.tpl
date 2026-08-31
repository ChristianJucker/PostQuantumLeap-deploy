{{/*
THE ENVIRONMENT CONTRACT — every setting the app receives, in one place.

⚠ A VALUE THAT IS NOT NAMED HERE IS NOT REACHABLE. This is the bug class
`docker-compose.yml` shipped twice: `config.py` read `ENGINE_VERSION` from the
environment and INSTALLATION.md documented it as a thing an operator sets, but
compose never listed it, and compose passes only the names it lists — so the
fleet-wide engine rollback lever could not be pulled at all, with no error to say
why. The same happened to the whole SCAN_* group. Both were found by running the
drill, not by reading the file.

Keeping every name in one template is what lets a test enumerate them. See
`values-registry` in the chart README.
*/}}
{{- define "pql.env" -}}
{{- $secret := include "pql.secretName" . -}}
{{- $dbHost := include "pql.dbHost" . -}}
{{- $db := .Values.externalDatabase -}}

# ── database ────────────────────────────────────────────────────────────────
- name: POSTGRES_PASSWORD
  valueFrom: {secretKeyRef: {name: {{ $secret }}, key: POSTGRES_PASSWORD}}
- name: APP_DB_PASSWORD
  valueFrom: {secretKeyRef: {name: {{ $secret }}, key: APP_DB_PASSWORD}}
{{/*
  Two DSNs since the database role split. The app connects as the
  least-privilege runtime role so Postgres row-security policies bind to it at
  all; migrations keep the owner identity, which is exempt from RLS by ownership
  — exactly what backfills need. `$(VAR)` is kubelet-side expansion of the two
  secret-backed variables above, so the password never appears in the manifest.
*/}}
- name: DATABASE_URL
  value: postgresql+asyncpg://{{ $db.appUser }}:$(APP_DB_PASSWORD)@{{ $dbHost }}:{{ $db.port }}/{{ $db.database }}{{ if not .Values.postgresql.enabled }}?ssl={{ $db.sslMode }}{{ end }}
- name: MIGRATION_DATABASE_URL
  value: postgresql+asyncpg://{{ $db.ownerUser }}:$(POSTGRES_PASSWORD)@{{ $dbHost }}:{{ $db.port }}/{{ $db.database }}{{ if not .Values.postgresql.enabled }}?ssl={{ $db.sslMode }}{{ end }}
- name: APP_DB_USER
  value: {{ $db.appUser | quote }}

# ── identity and crypto ─────────────────────────────────────────────────────
- name: SESSION_SECRET_KEY
  valueFrom: {secretKeyRef: {name: {{ $secret }}, key: SESSION_SECRET_KEY}}
- name: SETTINGS_ENC_KEY
  valueFrom: {secretKeyRef: {name: {{ $secret }}, key: SETTINGS_ENC_KEY}}
- name: INITIAL_ADMIN_USERNAME
  valueFrom: {secretKeyRef: {name: {{ $secret }}, key: INITIAL_ADMIN_USERNAME}}
- name: INITIAL_ADMIN_PASSWORD
  valueFrom: {secretKeyRef: {name: {{ $secret }}, key: INITIAL_ADMIN_PASSWORD}}

# ── the proxy in front, and what may be believed from it ────────────────────
{{- if eq .Values.ingress.mode "sidecar" }}
{{/*
  LOAD-BEARING. The app RENDERS AND PUSHES Caddy's whole configuration over the
  admin API at boot and on every TLS settings change, and its default upstream is
  `app:8000` — the compose service name, which resolves to nothing in a Pod. So
  editing the bootstrap ConfigMap is not enough: the pushed config overwrites it
  within seconds of boot, `--resume` restores the overwritten version on restart,
  and you get a 502 behind a valid certificate that COMES BACK after every
  restart. Measured twice on the spike cluster before this variable was set;
  config.py:157 records the identical 502 from the Azure deploy on 2026-08-06.
*/}}
- name: PROXY_UPSTREAM
  value: 127.0.0.1:8000
- name: PROXY_ADMIN_URL
  value: http://127.0.0.1:2019
{{- end }}
- name: TRUST_FORWARDED_FOR
  value: "true"
- name: TRUSTED_PROXY_HOPS
  value: {{ (eq .Values.ingress.mode "sidecar") | ternary 1 .Values.ingress.trustedProxyHops | quote }}
- name: TRUSTED_PROXY_CIDRS
  value: {{ include "pql.trustedProxyCIDRs" . | quote }}

# ── HTTP ────────────────────────────────────────────────────────────────────
{{/*
  Always true. The cookie carries Secure and HSTS is sent; TLS terminates either
  at the sidecar or at your ingress, and in both cases the browser is on HTTPS.
  There is no `HTTPS_ONLY=false` escape hatch in this chart because the compose
  one exists for reaching a LAN instance over plain HTTP from a phone, which has
  no Kubernetes analogue.
*/}}
- name: HTTPS_ONLY
  value: "true"
- name: CORS_ORIGINS
  value: {{ .Values.config.corsOrigins | default (printf "https://%s" (default "localhost" .Values.ingress.host)) | quote }}
- name: EXPOSE_API_DOCS
  value: {{ .Values.config.exposeApiDocs | quote }}

# ── scanning ────────────────────────────────────────────────────────────────
- name: SCAN_INTERVAL_HOURS
  value: {{ .Values.config.scanIntervalHours | quote }}
- name: SCAN_THROTTLING_MODE
  value: {{ .Values.config.scanThrottlingMode | quote }}
- name: SCAN_CONCURRENCY
  value: {{ .Values.config.scanConcurrency | quote }}

# ── remote engine ───────────────────────────────────────────────────────────
- name: REMOTE_ENGINE_LEASE_SECONDS
  value: {{ .Values.config.remoteEngine.leaseSeconds | quote }}
- name: REMOTE_ENGINE_JOB_TTL_SECONDS
  value: {{ .Values.config.remoteEngine.jobTtlSeconds | quote }}
- name: REMOTE_ENGINE_WATCHDOG_SECONDS
  value: {{ .Values.config.remoteEngine.watchdogSeconds | quote }}
{{/*
  Empty is the normal state and means "the build this server shipped with";
  version.py folds "" back to its own constant, because an empty advertised
  version would tell every engine it is stale forever. Forwarded so the
  fleet-wide rollback lever is REACHABLE — a bad engine build is un-advertised by
  setting one value here, effective at each engine's next connect, with no engine
  involvement. That matters because those engines sit in customers' segments and
  nobody has a shell on them.
*/}}
- name: ENGINE_VERSION
  value: {{ .Values.config.engineVersion | quote }}
- name: ENGINE_IMAGE_REF
  value: {{ .Values.config.engineImageRef | quote }}
- name: ENGINE_IMAGE_DIGEST
  value: {{ .Values.config.engineImageDigest | quote }}
{{- if ne .Values.engineImages.source "none" }}
{{/*
  Where the boot seeder looks for engine tarballs (ROAD-38). Only set when
  something actually mounts that path: `ensure_seeded_images` returns 0 for a
  missing directory, so pointing at nothing is harmless — but naming a directory
  that is never mounted is the kind of configuration that reads as a feature
  being on when it is not.
*/}}
- name: ENGINE_IMAGE_DIR
  value: /opt/engine-images
{{- end }}

# ── the instance's own TLS ──────────────────────────────────────────────────
- name: TLS_VOLUME_DIR
  value: /var/lib/pql/tls
{{- if eq .Values.ingress.mode "sidecar" }}
- name: TLS_SEED_ACME_DOMAIN
  value: {{ .Values.tls.acmeDomain | quote }}
- name: TLS_SEED_ACME_EMAIL
  value: {{ .Values.tls.acmeEmail | quote }}
- name: TLS_SEED_ACME_STAGING
  value: {{ .Values.tls.acmeStaging | quote }}
{{- end }}

{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}
