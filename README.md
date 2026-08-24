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
- **Docker** with **Compose v2** (`docker compose version` ≥ 2.0), or **Podman** 4.x+
  — see [Running under Podman](#9-running-under-podman)
- **Ports 80 and 443** free on the host. Caddy takes both; port 80 exists for the
  ACME challenge
- **Outbound network access** to the TLS endpoints you intend to scan
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

Keep the directory layout. `docker-compose.yml` mounts the last two by relative path,
so moving them breaks the start.

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
docker run --rm ghcr.io/christianjucker/pql-app:latest \
  python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

Two settings deserve a decision now rather than later:

**`INITIAL_ADMIN_USERNAME` must look like an e-mail address.** Sign-in is by address.
Anything else is rewritten to `<value>@unset.invalid`, which is a confusing way to find
out you cannot log in as the name you picked. It is an identifier, not a mailbox —
nothing is ever mailed to it.

**Pin `PQL_IMAGE` for anything you intend to keep.** The default is `:latest`, which is
right for a trial and wrong for a maintained installation: an unattended pull then moves
you across a release boundary at a moment you did not choose.

```bash
PQL_IMAGE=ghcr.io/christianjucker/pql-app:3.0.0
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

Download `pql-app-<version>.tar.gz` from this repository's
[Releases](https://github.com/ChristianJucker/PostQuantumLeap-deploy/releases), carry it
across, then:

```bash
sha256sum -c pql-app-<version>.tar.gz.sha256    # verify before loading
docker load < pql-app-<version>.tar.gz
```

Set `PQL_IMAGE` in `.env` to the exact tag the bundle carries (`docker images` after the
load shows it), and pre-stage `postgres:16` and `caddy:2.11.4` the same way — the stack
needs all three and only one of them is in the bundle.

---

## 9. Running under Podman

The compose file is Podman-compatible and needs no edits. Podman 4.x+ provides
`podman compose`; older installations use the separate `podman-compose`.

**Rootless Podman cannot bind ports below 1024**, and Caddy publishes 80 and 443. Either
run rootful (`sudo podman compose up -d`), or lower the threshold once on the host:

```bash
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-pql.conf
sudo sysctl --system
```

The second keeps the containers unprivileged, which is most of the reason to run Podman.

**SELinux is already handled** — the host bind mounts carry `:z`, so Fedora and RHEL
relabel automatically. Docker ignores the flag, so one file works on both.

⚠ **Known gap:** the remote-engine deployment commands generated in the browser still say
`docker`. They work under Podman if you substitute the command name by hand.

---

## 10. Your own registry

Mirror internally and point the whole deployment at your registry — no file edits, three
variables:

```bash
PQL_IMAGE=registry.example.com/pql-app:3.0.0
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
