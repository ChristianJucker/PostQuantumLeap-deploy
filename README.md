# Post Quantum Leap — deployment

Everything you need to run Post Quantum Leap, and nothing you do not. Clone or download
this repository, set four values, and start it.

**You do not build anything.** The application ships as a published container image;
this repository holds the compose file and configuration that run it. The product's
source is not here and is not needed.

- **Image:** `ghcr.io/christianjucker/pql-app` — public, no registry login required
- **Licence:** required. See below — order it before you start

---

## 0. Order your licence first

**Do this before you install anything.** Post Quantum Leap is licensed from day one:
there is no free evaluation period, and a trial licence is a real licence issued like any
other. Without one you can install, boot and sign in — and then stop at the licence page,
because nothing else is reachable until a licence is entered.

Order from **[info@postquantumleap.com](mailto:info@postquantumleap.com)**. You will be
sent a licence file; you paste its contents into the app at
[first login](#4-first-login), step 3. It is not a config file and it does not go in
`.env`.

**You do not need to tell us anything about your server to get it.** A licence is issued
*unbound* and binds itself to the first installation that uses it — so there is no
installation id to send us, no exchange to complete, and nothing to re-issue if you
rebuild the host later.

> **The image being public is not a licence to run it.** It is published for anonymous
> download so that nobody has to issue and rotate registry credentials — that is a
> packaging decision, not a commercial one.

---

## What you need

- **A licence** — see [above](#0-order-your-licence-first). Everything else on this list
  takes minutes to satisfy; the licence is the one that may not, so start it first
- **Docker** with **Compose v2** (`docker compose version` ≥ 2.0), or **Podman** 4.7+
  — see [Running under Podman](#9-running-under-podman)
- **`curl`** and **`git`** — used by the steps below to fetch these files and, on Podman,
  the Compose binary. `sudo apt install curl git` on Debian/Ubuntu, `sudo dnf install
  curl git` on Fedora/RHEL. A minimal server image often ships neither
- **Ports 80 and 443** free on the host. Caddy takes both; port 80 exists for the
  ACME challenge
- **Outbound network access** to the TLS endpoints you intend to scan
- An **amd64 or arm64** host. The published image is a multi-architecture manifest
  covering `linux/amd64` and `linux/arm64`, so `docker pull` fetches the right one and
  an Apple Silicon VM, an arm64 cloud instance or a 64-bit Raspberry Pi runs natively —
  no `qemu-user-static`, no emulation. Verify what you are about to run with
  `docker manifest inspect ghcr.io/christianjucker/pql-app:latest`
- Roughly **4 GB RAM** and **10 GB disk** to start; the database grows with your
  inventory and scan history

You do **not** need Python, Node.js, or a PostgreSQL install — all three run in
containers.

---

## 1. Get the files

```bash
git clone https://github.com/ChristianJucker/PostQuantumLeap-deploy.git postquantumleap
cd postquantumleap
```

No git? Download the ZIP from the green **Code** button and unpack it.

What you now have:

| File | Why it must be there |
|---|---|
| `docker-compose.yml` | the stack: database, application, TLS proxy |
| `.env.example` | template for your configuration |
| `deploy/caddy/bootstrap.json` | the proxy's starting configuration, mounted read-only |
| `deploy/engine-images/` | empty, and correct that way — see [Remote engines](#12-remote-engines) |
| `deploy/install-windows.ps1` | Windows only — does sections 1 to 3 for you, see below |
| `deploy/KUBERNETES.md` | Kubernetes only — a Helm chart instead of Compose, see below |
| `deploy/helm/` | the charts that guide installs |

Keep the directory layout. `docker-compose.yml` mounts `deploy/caddy/bootstrap.json`
and `deploy/engine-images/` by relative path, so moving them breaks the start.

### On Kubernetes

Compose is the simpler path and the one this guide follows. If you already run a
cluster, [`deploy/KUBERNETES.md`](deploy/KUBERNETES.md) covers the Helm chart
instead — including a `helm test` that proves your own ingress is wired correctly,
which is the one thing a Kubernetes install can get wrong silently.

It offers no capability Compose lacks, and Post Quantum Leap runs as a single
replica either way. If you are choosing between them, choose Compose.

### On Windows

Windows is a supported platform, and there is a script that does sections 1 to 3 for
you — prerequisite checks, the compose file, real generated secrets in `.env`, and
starting the stack.

⚠ **Pass `-InstallDir`.** You will usually be running from an elevated PowerShell,
because that is where the container runtime is reachable — and **elevation resets the
working directory to `C:\Windows\System32`**. The default install path is relative to
wherever you are, so it silently becomes `C:\Windows\System32\postquantumleap`, and
nobody notices until they go looking for their `.env`:

```powershell
.\deploy\install-windows.ps1 -InstallDir C:\ProgramData\PostQuantumLeap
```

It picks up whichever runtime you have. To force one:

```powershell
.\deploy\install-windows.ps1 -Runtime podman -InstallDir C:\pql
```

The script warns you if it detects that path, and it locks the install directory to
SYSTEM, Administrators and you before writing anything — `.env` holds every secret this
stack has, and the directories you would land in by accident grant read access to all
local users by inheritance. If it cannot apply or verify that lock, **it aborts instead
of writing the file.**

**It writes the same `.env` and runs the same `docker-compose.yml` a Linux operator
uses** — one supported deployment shape, not a Windows-shaped variant that drifts away
from it. So everything from section 4 onward applies to you unchanged, and so does
every troubleshooting entry below.

You still need a container runtime first; the script checks and tells you if one is
missing. **Podman Desktop is free for commercial use**, which is the usual reason to
prefer it — Docker Desktop requires a paid subscription above a company-size threshold.

> **If you already have a `.env`, the script keeps it and does not regenerate secrets.**
> That is deliberate: regenerating `SESSION_SECRET_KEY` signs every user out, and
> regenerating `SETTINGS_ENC_KEY` orphans every stored SSO secret — they cannot be
> decrypted afterwards. Delete the file deliberately if that is genuinely what you want.

---

## 2. Configure

```bash
cp .env.example .env
```

Open `.env` and set the four required values. The file carries the exact command to
generate each one; briefly:

```bash
# POSTGRES_PASSWORD and INITIAL_ADMIN_PASSWORD
openssl rand -base64 36

# SESSION_SECRET_KEY  (≥ 32 chars)
python3 -c "import secrets; print(secrets.token_urlsafe(48))"

# SETTINGS_ENC_KEY  (must be a real Fernet key, not any random string)
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

No Python on the host? Borrow the one in the image:

```bash
docker run --rm --entrypoint python ghcr.io/christianjucker/pql-app:latest \
  -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

`--entrypoint python` is required and is easy to lose when retyping this. The image
starts through `entrypoint.sh`, so without it `python` and everything after arrive as
*arguments to the entrypoint* rather than as the command — the container tries to
bootstrap a database, fails on the missing `DATABASE_URL`, and prints no key.

Two settings deserve a decision now rather than later:

**`INITIAL_ADMIN_USERNAME` must look like an e-mail address.** Sign-in is by address.
Anything else is rewritten to `<value>@unset.invalid`, which is a confusing way to find
out you cannot log in as the name you picked. It is an identifier, not a mailbox —
nothing is ever mailed to it.

**Pin `PQL_IMAGE` for anything you intend to keep.** The default is `:latest`, which is
right for a trial and wrong for a maintained installation: an unattended pull then moves
you across a release boundary at a moment you did not choose.

```bash
PQL_IMAGE=ghcr.io/christianjucker/pql-app:3.2.0
```

The versions actually published are listed at
**[packages/pql-app](https://github.com/users/ChristianJucker/packages/container/package/pql-app)** —
check there rather than trusting this example, which is a shape and not a promise.

> **Do not regenerate `SESSION_SECRET_KEY` or `SETTINGS_ENC_KEY` after go-live.** The
> first invalidates every session; the second makes an already-stored SSO client secret
> undecryptable.

---

## 3. Run

```bash
docker compose up -d
```

That pulls the images, starts PostgreSQL, applies all database migrations
(`alembic upgrade head` runs inside the app container on every start), and brings up
Caddy in front.

Watch it come up:

```bash
docker compose logs -f app
```

Then open **<https://localhost>**.

> **Your browser will warn on the first visit. That is the design.** Nothing has been
> issued for this instance yet, so Caddy serves a certificate from its own built-in local
> CA. The alternative would be a plaintext window during which somebody uploads a
> certificate over HTTP — so there is HTTPS from minute one instead, and a warning.
> [Certificates](#5-certificates) is how you replace it.

Ports 80 and 443 belong to Caddy. The application publishes only `127.0.0.1:8000` —
loopback, for local tooling — so it answers on the machine itself and from nowhere else.

---

## 4. First login

**The first account is a platform administrator that belongs to no tenant.** That is
deliberate, and it changes what you see: an account with no membership has no inventory
to render, so the platform console is the only surface the application can show it.

1. **Sign in** with `INITIAL_ADMIN_USERNAME` / `INITIAL_ADMIN_PASSWORD` from your `.env`.

2. **Change the password.** You must, before anything else is reachable. Signing in
   spends that credential, so you will be asked to sign in again afterwards.

3. **Enter your licence.** Paste the file you were sent — the whole dialog is that one
   field. Do not have one yet? See [Order your licence first](#0-order-your-licence-first);
   you are stopped here until it is entered.

   You are not asked for an installation id, and you should not be: a licence is issued
   *unbound* and binds itself to the first installation that uses it. A rebuilt
   installation loses that binding along with its identity and re-binds, so disaster
   recovery needs no re-issue and no support call.

   Signing in **always** works, in every licence state, and so does the page that accepts
   a licence — otherwise a lapsed installation could not be fixed by the person holding
   the replacement. An expired licence keeps working through 30 days of warnings before
   expiry and 14 days of grace after, then becomes read-only. **Your data is never taken
   away.** Afterwards the page lives at **Platform → Licence**.

4. **You land on `/platform`**, the installation console. Overview, Inventory and
   Compliance are absent because you are not a member of any tenant yet — those pages
   have nothing to resolve for you.

5. **Create the first tenant administrator.** The **Primary** tenant exists but has no
   members. Open **Members** on its row and create one. You get a **one-time setup
   link — copy it before closing the dialog**, because it is not stored anywhere you can
   read back.

6. **Redeem that link** (a private window, or send it to whoever will run the tenant),
   set a password, sign in. *That* is the login that sees the product: Overview,
   Inventory, Sources, Policy, Compliance and the tenant's own Admin.

7. A three-step **welcome wizard** (add a target → scan it → review) opens on that first
   tenant login. Skip it any time; reopen from **About → Setup guide**.

**Two accounts, deliberately — but one person may hold both.** The console administers
the installation; a tenant membership does the actual work. Someone holding the platform
flag *and* a membership lands in their tenant, and **Back to Platform console** at the
foot of the left rail switches modes.

---

## 5. Certificates

Caddy is configured **from the UI, not from a file you edit**. The app holds the desired
state, renders it as Caddy JSON, and pushes it to Caddy's admin API — which lives on the
container network and is never published to the host. Every push is the complete
configuration, applied or rejected in whole, so a change never takes the site down and
drift cannot accumulate.

Go to **Platform console → TLS** (`/platform?tab=tls`), platform administrators only.
The status card reports the certificate **observed on the wire** — the instance
handshakes its own endpoint with the same machinery it points at everything else, rather
than reporting the configuration it believes it applied.

Two ways to deal with the first-boot warning, and only one is permanent:

- **Verify the fingerprint.** The TLS tab shows the fingerprint measured on the wire.
  Compare it with your browser's and you know you are talking to this instance.
- **Trust the CA root.** The TLS tab offers **Download local CA root (.pem)**. Install it
  in the trust stores that ought to trust this instance and the warning goes for good.

> A written-down fingerprint does not survive: the local CA rotates its intermediate on a
> seven-day cycle and a leaf cannot outlive its issuer, so the served certificate turns
> over on that cadence. **Trusting the root is what lasts.**

**Getting a real certificate** — set it in the TLS tab, or seed ACME at first boot by
setting `TLS_SEED_ACME_DOMAIN` and `TLS_SEED_ACME_EMAIL` in `.env` before the first start.
The name must already resolve to this host or the challenge fails.

> **Do your first ACME run against staging** (`TLS_SEED_ACME_STAGING=true`). The
> certificates are untrusted, but there is no rate limit — and the production rate limit
> is low enough to lock you out for a week over a typo in the domain name.

The seed applies to the **first boot only** and never overwrites an existing
configuration. After that the TLS tab owns the setting.

---

## 6. Upgrading

```bash
docker compose pull
docker compose up -d
```

Same `.env`, same volumes. `alembic upgrade head` runs the new migrations **in place**
against your existing data on every start. This never wipes inventory, users or
configuration.

If you pinned `PQL_IMAGE` (and you should have), edit the tag first — `docker compose
pull` on a pinned tag re-fetches the same image and changes nothing.

> **Do not run two versions against one database at once.** `docker compose up -d` stops
> the old container before starting the new one, so a normal upgrade is fine. What to
> avoid is a rolling upgrade, a second manually started container, or a leftover
> `uvicorn --workers 2` — two versions can scan the estate simultaneously because their
> advisory locks occupy different lock spaces and do not exclude each other.

> **Coming from a build older than 2.1?** 2.1 is the upgrade floor and such an instance is
> reset once when 2.1 is deployed. Export anything you need first.

> **Upgrading to 3.1.0 makes stored credentials one-way.** 3.1.0 changes how the SSO
> client secret and proxy passwords are encrypted at rest: existing values keep working
> unchanged, but any credential you **re-save** after upgrading is written in the new
> format, which 3.0.0 cannot read. So a rollback to 3.0.0 is safe *until* you re-enter a
> secret — after that, rolling back leaves that one credential unreadable and it has to be
> entered again. Nothing else about the upgrade is one-way, and you do not need to
> re-enter anything to upgrade.

> **Upgrading an install created before 2026-08-24 needs `docker compose up -d
> --force-recreate` once.** The proxy moved to a fixed network address. Compose recreates
> only containers whose own configuration changed, so a plain `up -d` rebuilds the proxy
> onto the new network and leaves an unchanged `app` container stranded off it — which
> then cannot resolve `db` and crash-loops with `Name or service not known`, reading like
> a database fault. `--force-recreate` replaces containers, not volumes; your database is
> untouched.

---

## 7. Back up the volumes — a database backup is not a key backup

**Private keys are never stored in the database.** That is deliberate: a database dump is
key-free, which is the thing certificate-handling policies actually audit. The
consequence is that a database backup does not restore your TLS.

| What | Where | Losing it means |
|---|---|---|
| Your inventory, users, configuration | `postgres_data` | everything — this is the primary backup |
| Uploaded and CSR-generated keys and chains | `tls_certs` | re-uploading the certificate, or re-running the CSR flow |
| ACME account, issued certificates, the local CA | `caddy_data` | Caddy re-orders (ACME repairs itself); a self-signed instance gets a **new local CA**, so the root you distributed no longer matches |

```bash
# Database
docker compose exec -T db pg_dump -U postquantumleap postquantumleap | gzip > pql-$(date +%F).sql.gz

# Key material
docker run --rm -v postquantumleap_tls_certs:/v -v "$PWD:/out" alpine \
  tar czf /out/tls_certs-$(date +%F).tar.gz -C /v .
docker run --rm -v postquantumleap_caddy_data:/v -v "$PWD:/out" alpine \
  tar czf /out/caddy_data-$(date +%F).tar.gz -C /v .
```

Nothing here is unrecoverable — the TLS tab can re-provision all of it — but it is
manual, and on an instance whose CA root you distributed to a fleet it is visible to
everybody.

---

## 8. Air-gapped installs

**There is one bundle per architecture, and you need the one that matches the machine you
will run it on.** `docker save` writes a single platform per file — there is no "both"
download. Check first, on the target machine:

```bash
uname -m
```

`x86_64` means **amd64**; `aarch64` or `arm64` means **arm64**.

Download the matching pair from this repository's
[Releases](https://github.com/ChristianJucker/PostQuantumLeap-deploy/releases), carry them
across, then:

```bash
sha256sum -c pql-app-<version>-amd64.tar.gz.sha256    # verify before loading
docker load < pql-app-<version>-amd64.tar.gz
```

Set `PQL_IMAGE` in `.env` to the exact tag the bundle carries (`docker images` after the
load shows it), and pre-stage `postgres:16` and `caddy:2.11.4` the same way — the stack
needs all three and only one of them is in the bundle.

> **Loading the wrong architecture is not silent, but it is disguised.** The container
> starts and dies immediately with `exec container process … exec format error`, repeating
> forever, and the app never appears in `docker compose ps` — only the database and the
> proxy do. That reads like a broken image rather than the wrong one. `docker rmi` the tag
> and load the other file.

> **Releases before `3.1.0` carry a single `pql-app-<version>.tar.gz` with no architecture
> in the name.** Those are **amd64**, because that is what the runner that built them was.

---

## 9. Running under Podman

Podman works, but **only through a real Compose implementation**. Take one of these two
routes; the third thing you might reach for does not work, and §9.1 says why.

**Podman 4.7 or newer** — `podman compose` is a thin wrapper that delegates to real Compose:

```bash
podman compose up -d
```

**Podman older than 4.7** — there is no `compose` subcommand at all, and
`podman compose up -d` fails with `Error: unknown shorthand flag: 'd' in -d`, which reads
like a bad flag and is really a missing command. Point real Compose at Podman's
Docker-compatible socket instead.

Compose v2 ships as a **single self-contained binary**. You do not need Docker installed —
this is the whole point, and `docker compose` (with a space) is the wrong command here
because that subcommand belongs to the Docker CLI you do not have. Use `docker-compose`,
with a hyphen:

```bash
mkdir -p ~/.local/bin
curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o ~/.local/bin/docker-compose
chmod +x ~/.local/bin/docker-compose
export PATH="$HOME/.local/bin:$PATH"
```

`$(uname -m)` resolves to the right asset on both architectures — `aarch64` and `x86_64`
are exactly what those releases are named.

Then start the socket and point Compose at it. **Ask Podman where its socket is rather
than assuming** — it lives in a `podman/` subdirectory of the runtime dir
(`/run/user/1000/podman/podman.sock`), not directly in it, and hardcoding the shorter path
fails with `dial unix /run/user/1000/podman.sock: connect: no such file or directory`
*after* the socket has started perfectly well:

```bash
systemctl --user enable --now podman.socket
export DOCKER_HOST="unix://$(podman info --format '{{.Host.RemoteSocket.Path}}')"
docker-compose up -d
```

If that still cannot connect, check the socket is actually running and see the path it
reports:

```bash
systemctl --user status podman.socket
podman info --format '{{.Host.RemoteSocket.Path}} exists={{.Host.RemoteSocket.Exists}}'
```

`Exists=false` means the unit is enabled but not started — `systemctl --user start
podman.socket`.

Both `export` lines last only for that shell. Put them in `~/.bashrc` if you want
`docker-compose` to keep finding Podman in new terminals.

Check which Podman you have with `podman --version` before any of this.

> **Everywhere else in this guide writes `docker compose`** — upgrading, backups,
> troubleshooting, logs. On this route substitute **`docker-compose`** (hyphen) in every
> one of them, and keep `DOCKER_HOST` exported. Nothing else changes.

### 9.1 `podman-compose` is not supported

`podman-compose` is a separate reimplementation rather than a wrapper, and it cannot run
this compose file. Measured on **podman-compose 1.0.3 with Podman 4.3.1 (Debian 12)**,
two failures we cannot fix from our side:

- **It does not expand `${VAR:-default}`.** `docker-compose.yml` builds the app's database
  URL from `${APP_DB_PASSWORD:-${POSTGRES_PASSWORD}}`, and podman-compose passed the string
  through *literally* — the container was handed `pql_app:${POSTGRES_PASSWORD}` as its
  password. Simple `${VAR}` worked; the default-value and nested forms did not. Nothing
  errors; the app just cannot authenticate to its own database.
- **It crashes on the proxy's static address.** The compose file pins Caddy to a fixed
  IPv4 address so that `TRUSTED_PROXY_CIDRS` can name it as a `/32`, and podman-compose
  aborts with `KeyError: "default={'ipv4_address': '172.28.0.10'}"` before starting it.

Both are limitations of that tool, not of Podman. Either route above avoids them, because
both hand the file to the same Compose implementation Docker uses.

### Rootless, and ports below 1024

**Rootless Podman cannot bind ports below 1024**, and Caddy publishes 80 and 443. Either
run rootful (`sudo podman compose up -d`), or lower the threshold once on the host:

```bash
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-pql.conf
sudo sysctl --system
```

The second keeps the containers unprivileged, which is most of the reason to run Podman.

### Two things already handled

**Image names are fully qualified.** Podman refuses a short name — `Error: short-name
"postgres:16" did not resolve to an alias and no unqualified-search registries are
defined` — where Docker silently assumes Docker Hub. The compose file writes
`docker.io/library/...` out in full, so neither runtime has to guess and you do not need
to edit `/etc/containers/registries.conf`.

**SELinux is handled** — the host bind mounts carry `:z`, so Fedora and RHEL relabel
automatically. Docker ignores the flag, so one file works on both.

⚠ **Known gap:** the remote-engine deployment commands generated in the browser still say
`docker`. They work under Podman if you substitute the command name by hand.

---

## 10. Your own registry

Mirror internally and point the whole deployment at your registry — no file edits, three
variables:

```bash
PQL_IMAGE=registry.example.com/pql-app:3.2.0
PQL_POSTGRES_IMAGE=registry.example.com/postgres:16
PQL_CADDY_IMAGE=registry.example.com/caddy:2.11.4
```

Separate variables rather than one prefix, because Docker Hub images carry an implicit
`library/` namespace that a naive prefix breaks.

---

## 11. Bring your own ingress

To terminate TLS in your own nginx, F5 or cloud load balancer, keep Caddy out of the way:

```bash
docker compose up -d --scale caddy=0
```

Set `PROXY_ADMIN_URL=` (empty) in `.env` — the TLS tab still renders, but every push
becomes a recorded no-op, which is the honest reflection of "no managed proxy". Keep
`HTTPS_ONLY=true`.

Then **four conditions govern client-IP trust**, and they are yours now rather than the
shipped stack's:

1. **`TRUSTED_PROXY_CIDRS` must list your proxies' own addresses** — required at every
   hop count, including the default of 1. Keep the set tight: anything inside it is
   trusted to speak for any client.
2. **Your proxy must APPEND to `X-Forwarded-For`, not pass it through.** nginx:
   `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`. The misconfiguration
   to look for is `$http_x_forwarded_for`, which forwards the client's header untouched;
   a plain L4 load balancer does the same by doing nothing. **The app cannot detect
   this** — a one-entry chain looks identical either way — so it is on you, and it is the
   one to check first.
3. **The app's port must not be reachable except through that proxy.** If you re-publish
   `8000` and the proxy is not the only route to it, anyone who can open a socket can
   forge the whole header chain.
4. **Hop count must match the number of appending proxies.** Too low is the safe
   direction; too high is the unsafe one.

Miss 1, 3 or 4 and the app falls back to one shared rate-limit bucket — which delays and
never refuses, so it warns rather than refusing to boot. Condition 2 it cannot check.

---

## 12. Remote engines

To scan networks this server cannot reach, deploy a remote engine into that segment and
it polls the server for work — no inbound firewall rule required. Set it up from
**Admin → Bifröst**, which generates the deployment command.

`deploy/engine-images/` is empty here and correct that way: engine images are fetched at
setup time rather than shipped with the compose file.

---

## 13. Troubleshooting

**`docker compose up` exits immediately, logs mention a secret.** The app refuses to boot
on a short or default `SESSION_SECRET_KEY` outside development. Regenerate it.

**`SETTINGS_ENC_KEY` errors on boot.** It must be a real Fernet key — 44 URL-safe base64
characters from `Fernet.generate_key()`, not an arbitrary random string.

**`Name or service not known` right after an upgrade.** The app container is stranded off
the new network. `docker compose up -d --force-recreate` — see [Upgrading](#6-upgrading).

**The login form bounces back with no error.** A `Secure` cookie cannot be stored over
plain HTTP. Use `https://localhost`, not `http://` on a LAN address. `HTTPS_ONLY=false`
is the deliberate escape hatch for a trusted LAN and nowhere else.

**Port 80 or 443 already in use.** Something else holds them — `sudo lsof -i :443`. Stop
it, or [bring your own ingress](#11-bring-your-own-ingress).

**`Illegal instruction` during `alembic upgrade head`, and the app crash-loops.** Seen on
Debian 12 arm64 under Parallels with Podman 4.3.1; not seen on Ubuntu 24.04 arm64 or on
macOS/Docker with the same image.

The crash is inside `import cryptography.x509`, while the bundled OpenSSL in that wheel runs
its aarch64 capability probe — which reads CPU ID registers through an instruction the
kernel has to trap and emulate. Where it does not, the probe itself is the illegal
instruction. Confirm in one command:

```bash
docker compose run --rm -e OPENSSL_armcap=0 --entrypoint python app -c "import cryptography.x509; print('OK')"
```

If that prints `OK`, make it permanent with a `docker-compose.override.yml` beside the
compose file — Compose merges it automatically, and it affects nothing else:

```yaml
services:
  app:
    environment:
      OPENSSL_armcap: "0"
```

**This costs performance and is not a default for that reason.** Setting it to `0` turns off
OpenSSL's hardware AES and SHA acceleration, which a product that spends its time on TLS
handshakes will feel. Use it where it is needed and nowhere else. A newer kernel — Ubuntu
24.04 rather than Debian 12 — avoids the problem without the penalty.

**Do not set `OPENSSL_armcap` empty to "unset" it.** OpenSSL reads it with `getenv` and
parses any non-null value with `strtoul`, so an empty string means **0**, silently disabling
the very acceleration you were trying to keep. Either define it as `"0"` or leave it out of
the file entirely.

**`exec container process ... Exec format error`, repeating forever, and the app is missing
from `docker compose ps`.** This is the *same* cause as the platform warning below, wearing
a much worse disguise: the container holds an amd64 binary and the host is arm64, so it
cannot execute at all and crash-loops. The app never appears as a running service; only the
database and proxy do, which makes it look like the app image is broken rather than simply
the wrong architecture.

**`docker compose down -v` does not fix it.** That removes volumes, not images — so an
image pulled before the multi-arch release survives every teardown and gets reused on every
`up`. Delete the image itself:

```bash
docker compose down
docker rmi -f ghcr.io/christianjucker/pql-app:latest ghcr.io/christianjucker/pql-app:3.2.0
docker compose pull
docker compose up -d
```

Then check what you actually have, before looking at anything else:

```bash
docker image inspect ghcr.io/christianjucker/pql-app:latest --format '{{.Os}}/{{.Architecture}}'
```

**On arm64: "The requested image's platform (linux/amd64) does not match the detected host
platform (linux/arm64/v8)".** The published image carries both architectures, so this means
your machine still holds the image it pulled *before* the multi-arch release — `up` reuses
a tag that already exists locally rather than re-resolving it against the registry.

```bash
docker compose down
docker compose pull
docker compose up -d
```

If it survives that, the tag is still mapped to the old digest. Drop it and pull again:

```bash
docker rmi ghcr.io/christianjucker/pql-app:latest ghcr.io/christianjucker/pql-app:3.2.0
docker compose pull
```

Confirm what the registry actually offers — this needs no credentials and no local state:

```bash
docker buildx imagetools inspect ghcr.io/christianjucker/pql-app:3.2.0
```

That must list `linux/amd64` **and** `linux/arm64`. If it does and you still get the
warning, the problem is local caching every time.

**`requested static ip 172.28.0.10 not in any subnet on network
postquantumleap_default`.** The network already exists and was created by something else —
almost always a failed earlier attempt, and `podman-compose` in particular creates it with
podman's own default subnet and no ipam configuration. A network is only configured when
it is *created*, so Compose cannot apply the `172.28.0.0/16` the compose file declares to
one that is already there, and the proxy's fixed address then belongs to no subnet.

Delete the network and let Compose make it properly:

```bash
docker compose down
docker network rm postquantumleap_default     # podman network rm ... under Podman
docker compose up -d
```

**If that reports `has associated containers with it`,** something other than Compose is
still attached. `podman-compose` names containers with **underscores**
(`postquantumleap_db_1`) where real Compose uses **hyphens** (`postquantumleap-db-1`), so
`down` removes its own and leaves the others holding the network. See what is there, then
remove them:

```bash
podman ps -a --filter name=postquantumleap --format '{{.Names}}\t{{.Status}}'
podman rm -f $(podman ps -aq --filter name=postquantumleap_)
```

**On a fresh install, wiping is cheaper than untangling** — and it avoids a trap. **Postgres
reads `POSTGRES_PASSWORD` only when it initialises the data directory.** If a failed attempt
created the volume and you have since regenerated `.env`, the database still holds the *old*
password, the app cannot authenticate, and nothing in the error says so. `docker compose down
-v` destroys the volumes and every bit of data in them, which on a first install is nothing:

```bash
docker compose down -v
```

The fixed address is not decoration: `TRUSTED_PROXY_CIDRS` names it as a `/32`, and that is
what stops anything else on the bridge from forging the client IP the login rate limiter
keys on. Do not "fix" this by deleting the static address from the compose file.

**Start over completely.** `docker compose down -v` destroys the volumes and therefore
every bit of data, TLS material and the local CA. There is no undo.

Collect diagnostics for support:

```bash
docker compose logs --no-color --tail 500 > pql-logs.txt
docker compose ps -a >> pql-logs.txt
```

---

## Support

[info@postquantumleap.com](mailto:info@postquantumleap.com)

Include your version (**About** page, or `docker compose exec app python -c "from
app.version import RELEASE_VERSION, BUILD_VERSION; print(RELEASE_VERSION, BUILD_VERSION)"`)
and the diagnostics above.

Managed cloud deployment — a single container group plus managed PostgreSQL behind a
proxy for ACME TLS — runs cleanly and is supported; the provisioning script is maintained
privately. Ask.

---

© 2026 Christian Jucker. The Post Quantum Leap application is proprietary and licensed
separately; see `LICENSE` for what these deployment files may be used for.
