# Deploying & developing gemini_addons18

This repo is the **authoritative source** of the Odoo 19 solution. It ships a
complete Docker stack (Odoo + PostgreSQL). Odoo core is the official `odoo:19`
image (this repo's custom code lives in `/opt/extra-addons`); pin the image for
reproducibility instead of vendoring the multi-hundred-MB Odoo source.

```
docker-compose.yml            prod / Dokploy (Odoo + Postgres)
docker-compose.override.yml   local dev overlay (ports, live mount, reload)
Dockerfile                    odoo:19 + python reqs + entrypoint
docker/entrypoint.sh          render conf <- env, wait db, auto -i/-u, serve
docker/odoo.conf.template     all odoo.conf keys <- ${ENV}
.env.example                  every tunable
```

Everything is configured through `.env` (`cp .env.example .env`). Nothing odoo
needs is hard-coded.

---

## Local development

Requirements: Docker + Docker Compose, and the `_vendor` submodules populated:

```bash
git submodule update --init --recursive
make hooks                    # once per clone: pre-commit checks (layout +
                              # selection_reasons.md coverage, see platform/README.md)
cp .env.example .env          # then edit secrets
make up                       # build + start (publishes 8069/8072, live reload)
make logs
```

First run on a fresh database — create and init it once:

```bash
INIT_DB=odoo make up          # creates db "odoo" with base + own modules
# then clear INIT_DB from .env so it doesn't re-check every boot
# open http://localhost:8069  (master pw = ADMIN_PASSWD)
```

### Debugging (VS Code + debugpy)

The repo ships `.vscode/launch.json` + `tasks.json` (debugger setup is shared;
personal `.vscode` scratch stays gitignored).

```bash
make debug            # = DEBUG=1 DEBUGPY_WAIT=1 docker compose up --build
```

Then in VS Code run **"Odoo: Attach (Docker debugpy)"** (port 5678). Breakpoints
in your modules map via `${workspaceFolder} -> /opt/extra-addons`. `DEBUGPY_WAIT`
blocks boot until you attach; drop it to start immediately and attach anytime.
Debugging forces single-process (the dev overlay already sets `WORKERS=0`).

> Prefer running Odoo natively (no Docker) against your local source? The
> multi-root `odoo18.code-workspace` still has the **"Python: Odoo"** launch
> config that runs `odoo-bin` directly.

The dev overlay bind-mounts the repo into the container, so editing python/xml
hot-reloads (`--dev=reload,qweb,xml`). Useful targets (`make help`):

| target            | what |
|-------------------|------|
| `make up/down`    | start / stop stack |
| `make logs`       | tail odoo |
| `make shell`      | bash in container |
| `make odoo-shell` | odoo python shell |
| `make psql`       | psql into the db |
| `make upgrade`    | `-u` own modules (`m=mod1,mod2` to target) |
| `make submodules` | bump `_vendor` to latest 19.0 |

> The override disables boot-time auto-upgrade so restarts are fast. Upgrade
> explicitly with `make upgrade`.

---

## Production via Dokploy

1. **Create app** → type **Compose**, point it at this git repo, branch `19.0`,
   compose file `docker-compose.yml` (the repo-root one — see "Root compose is a
   symlink" below). Enable **recursive submodule** clone so
   `third_party_addons/_vendor` is populated.
2. **Environment** → paste your `.env` values (at minimum `ADMIN_PASSWD`,
   `DB_PASSWORD`). For a fresh database set `INIT_DB=<name>` on the first
   deploy, then clear it. Set `UPGRADE_DB=<name>` for ongoing upgrades.
3. **Domain** — two options:
   - *UI (simplest):* add **two** domain entries, both host `odoo.example.com`,
     both service `odoo`, HTTPS + letsencrypt:

     | Path | Port | Purpose |
     |------|------|---------|
     | `/`  | 8069 | normal HTTP traffic |
     | `/websocket` | 8072 | longpolling/gevent — **required** when `WORKERS>0` |

     Without the second entry the websocket falls through to 8069 and the UI
     hangs on "connection lost" / live chat + notifications stop working.
   - *Compose labels:* set `DOMAIN` in env, uncomment the Traefik `labels` +
     `networks` blocks in `docker-compose.yml`. The second router sends
     `/websocket` to `GEVENT_PORT` — same split as the two UI entries above.

   Multi-db stack (e.g. prod + staging): repeat the domain pair for **every**
   host and set `DBFILTER=(?i)^%d$` — see *Host → database routing* below.
4. **Deploy.** On boot the entrypoint renders the config, waits for Postgres,
   creates any `INIT_DB` databases, upgrades every `UPGRADE_DB` database, and
   serves. Missing dbs in `UPGRADE_DB` are skipped (never auto-created).

`PROXY_MODE=True` is required behind Traefik. Volumes `db-data` and `odoo-data`
(filestore + sessions) persist across redeploys.

### Root compose is a symlink (don't turn it back into a wrapper)

The product repo's root `docker-compose.yml` is a **symlink** to
`platform/docker-compose.yml`, not a thin `include:` wrapper. This is load-bearing:

* Dokploy's **domain** feature parses the compose file *statically* and does
  **not** expand `include:`. A wrapper therefore exposes zero services, and
  attaching a domain fails with *"service odoo does not exist in the compose"*.
  A symlink presents the real `services:` (`db`, `odoo`) at the repo root.
* Pointing Dokploy **directly** at `platform/docker-compose.yml` is *not* a fix:
  compose then sets the project dir to `./platform`, so `context: .` and
  `dockerfile: platform/Dockerfile` resolve to `platform/platform/*` (build
  fails), **and** the repo-root `.env` Dokploy writes is no longer auto-loaded
  (prod loses `DB_PASSWORD`, `ADMIN_PASSWD`, …).
* The symlink keeps the project dir at the repo root, so build paths and the
  root `.env` resolve exactly as they do locally — while the stack stays shared
  in the submodule (no per-product duplication).

Keep Dokploy's **Compose Path = `./docker-compose.yml`**. `make up` and the
Makefile already use this same root path, so nothing else changes.

### Private submodules & Dokploy auth

Dokploy authenticates only the **top-level** clone. Its GitHub-App provider
injects a token into the parent URL, but that token is **never** passed to
submodule clones — so a **private** `_vendor` submodule fails with
`could not read Username for 'https://github.com'`. Which fix you need depends on
whether the submodule lives under the **same GitHub account** as the product repo:

**A. Same account → relative URL (no secret).**
If the product repo and the private submodule are under the same owner (e.g.
both under `T-Altendorf`), keep Dokploy on the **GitHub-App provider** and make
the submodule URL **relative** in `.gitmodules`:

```ini
[submodule "src/third_party_addons/_vendor/organize_urself"]
	url = ../organize_urself.git        # NOT https://…/T-Altendorf/organize_urself.git
```

Git resolves a relative submodule URL against the parent's *authenticated* origin
URL, so it inherits the App token automatically. Requirements: the Dokploy GitHub
App is installed on that account with access to **both** repos, and recursive
submodules are enabled. This is the preferred pattern — zero keys.

**B. Cross-account → SSH provider + account key.**
If the submodule is under a **different** owner than the product repo (e.g. repo
under `GeminiLabTec`, submodule under `T-Altendorf`), a relative URL would inherit
the *wrong* account's token and still fail. Instead switch the whole app to SSH,
because Dokploy's generic **Git provider** exports `GIT_SSH_COMMAND` for the whole
clone and git **does** propagate that to submodules:

1. Register an **account-level** SSH key (Settings → SSH keys, *not* a per-repo
   deploy key) on an account that can read **both** repos — i.e. it owns the
   product repo and is a **collaborator** on the submodule repo.
2. In Dokploy set the app source to the **Git provider** with the **SSH** URL
   (`git@github.com:OWNER/repo.git`, colon before owner, trailing `.git` — an
   `https://…` URL silently skips all SSH/known_hosts setup and clones over HTTPS).
   Attach the key; keep submodules enabled.
3. Set the submodule URL in `.gitmodules` to SSH too
   (`git@github.com:OWNER/submodule.git`).

Dokploy then runs `ssh-keyscan` (populating `known_hosts`, which fixes
`Host key verification failed`) and reuses the same key + known_hosts for the
recursive submodule clone.

**Local dev with pattern B:** the SSH `.gitmodules` URL fails on dev machines
that authenticate to GitHub via `gh` over HTTPS (no registered SSH key). Don't
change `.gitmodules` — run `make dev-remotes` (also part of `make submodules`),
which rewrites `git@github.com:` submodule URLs to HTTPS in **local** git config
and the submodule's origin only. One-time prerequisite: `gh auth setup-git`.

> ⚠️ GitHub free/Education plans can't set a collaborator to **read-only** — the
> collaborator gets **write**, and the account key could therefore push to the
> submodule repo. Compensate with **branch protection** on the submodule's
> deploy branch (require a PR, block direct/force pushes); that needs GitHub Pro.

### Ports & reverse proxy (no host ports in prod)

In production the odoo container publishes **zero** host ports — it only
`expose`s 8069 (http) and 8072 (websocket) on the docker network. A reverse
proxy on that same network maps your domain to those internal ports. This is the
docker-native version of your host-nginx `upstream 127.0.0.1:8070` — the
upstream just becomes the **service name + internal port**:

| your old host nginx        | dockerized                |
|----------------------------|---------------------------|
| `server 127.0.0.1:8070;`   | `server odoo:8069;`       |
| `server 127.0.0.1:8073;`   | `server odoo:8072;`       |
| nginx listens 80/443       | only the proxy publishes ports |

Two ways to run the proxy:

- **Dokploy/Traefik** — add **two** domain entries in the UI for the same host
  (`/` → 8069 and `/websocket` → 8072), or use the `${DOMAIN}` labels in
  `docker-compose.yml`. Traefik sets `X-Forwarded-*` and terminates TLS; you
  publish nothing. The `/websocket` route is required when `WORKERS>0`.

  Dokploy's Traefik sends responses **uncompressed** unless told otherwise, and
  Odoo never compresses on its own — the backend JS bundle alone is several MB
  raw and is re-downloaded after every deploy (its hash changes). Enable it once
  per host, for every site behind that Traefik: define a `compress` middleware
  in `/etc/dokploy/traefik/dynamic/middlewares.yml` (exclude
  `text/event-stream`, compression buffers SSE) and attach `compress@file`
  under `entryPoints.websecure.http.middlewares` in
  `/etc/dokploy/traefik/traefik.yml`, then reload Traefik (static config; all
  sites blink). The Domains UI cannot attach middlewares. Verify with a GET —
  `curl -I` is a HEAD, has no body, and never shows `content-encoding`:
  `curl -s -o /dev/null -H 'Accept-Encoding: gzip, br' -w '%header{content-encoding}\n' https://<host>/web/login`.
  The self-managed nginx below already has `gzip on`.
- **Self-managed nginx** (mirrors your current vhost exactly):
  ```bash
  docker compose -f docker-compose.yml -f docker-compose.nginx.yml up -d
  ```
  Config lives in `deploy/nginx/templates/default.conf.template` (driven by
  `${DOMAIN}`). Mount your existing `/etc/letsencrypt` to terminate TLS there,
  or keep it HTTP behind Dokploy. Don't combine with the dev override.
- **Inner VPN, no reverse proxy** — see "Dangerously exposed ports" below.

### Dangerously exposed ports (opt-in, off by default)

Neither `db` nor `odoo` publishes a host port in prod. Two overlay files can
turn that on, kept **separate** on purpose so enabling VPN access to the odoo
UI never drags raw Postgres onto the network with it.

| overlay | publishes | env |
|---|---|---|
| `platform/docker-compose.dangerously-expose-odoo.yml` | odoo http + websocket | `ODOO_EXTERNAL_PORT` (8069), `ODOO_EXTERNAL_GEVENT_PORT` (8072) |
| `platform/docker-compose.dangerously-expose-db.yml` | raw Postgres | `DB_EXTERNAL_PORT` (5432) |

Enable by listing the overlay in `COMPOSE_FILE` in the product's `.env` —
colon-separated, relative to the repo root, base file first:

```bash
# odoo on an inner-VPN box with no proxy in front
COMPOSE_FILE=docker-compose.yml:platform/docker-compose.dangerously-expose-odoo.yml
PROXY_MODE=False                 # nothing is terminating in front now

# postgres, one-off remote dump/restore — REMOVE and redeploy afterwards
COMPOSE_FILE=docker-compose.yml:platform/docker-compose.dangerously-expose-db.yml
DB_EXTERNAL_PORT=5433
```

Compose reads `COMPOSE_FILE` from `.env`, so nothing else changes; without it
the overlays are never loaded and `docker compose ps` shows no published ports.

> ⚠️ These bind `0.0.0.0` and bypass TLS entirely — odoo serves its login page
> over plain HTTP, and Postgres is cleartext TCP guarded only by `DB_PASSWORD`.
> Only enable on a box that is not publicly reachable, and firewall the ports
> to the VPN subnet / your own IP. Two stacks on one host will collide on these
> ports — give one different `*_EXTERNAL_*` values.

Two things that do **not** work, both verified the hard way:

* **A `ports:` entry on `odoo`/`db` with an "empty = off" default.** A `ports:`
  entry always publishes; an empty host port just publishes on a *random*
  public port (`0.0.0.0:60141->8069/tcp`), which is worse than a fixed one.
* **A profile-gated sidecar with `network_mode: "service:odoo"` + `ports:`.**
  `docker compose config` validates it, but `up` always fails with
  `conflicting options: port publishing and the container type network mode` —
  a container sharing another's netns cannot publish ports. Overlay files are
  the only mechanism that actually yields *zero* published ports by default.

> **Dokploy:** it invokes compose with an explicit `-f`, which overrides
> `COMPOSE_FILE`. Verify on the target app that the ports really appear before
> relying on this there; the `.env` route is what the Makefile/CLI uses.

### Host → database routing (multi-db, staging subdomains)

Odoo picks the database **per request, before URL routing**, from exactly two
sources (`_get_session_and_dbname` in `odoo/http.py`): the session cookie, or —
for fresh sessions — *"exactly one db matches the dbfilter"*. The `?db=` query
param only helps on `auth='none'` routes (`/web/login`, the db manager), where
`ensure_db()` seeds the session. Emailed links — `/web/signup` invitations,
`/web/reset_password` — are `auth='public'` routes, which **do not exist** for
a db-less request. Consequence, verified the hard way: with two dbs and
`DBFILTER=.*`, every invitation/reset link 404s for anyone without a session
cookie; deleting the second db "fixes" it because the exactly-one path fires
again. Multiple dbs on **one** hostname can therefore never fully work — the
mapping host → db must be unique.

**Standard scheme — subdomain == db name (case-insensitive):**

```bash
DB_NAME=False
DBFILTER=(?i)^%d$
```

`%d` is the first DNS label of the request host (`odoo.example.com` → `odoo`,
`odoo-staging.example.com` → `odoo-staging`); `%h` would be the full host.
Each host then matches exactly one db, with zero proxy configuration. The
`(?i)` makes the match case-insensitive: hostnames always arrive lowercase,
so a legacy mixed-case db (`AltendorfIT` @ `altendorfit.example.com`) works
**without a rename** — renames are only needed when the *name* differs, not
the case. (Plain `^%d$` if you prefer enforcing lowercase db names.) Rules:

* subdomain must equal the db name ignoring case — and never keep two dbs
  differing only by case, both would match.
* every host needs its own Dokploy domain pair (`/` → 8069, `/websocket` → 8072).
* fleet convention: prod db `odoo` @ `odoo.example.com`, staging db
  `odoo-staging` @ `odoo-staging.example.com` — same container, same Postgres,
  mutually invisible before login. Refresh staging with
  `make dbtest from=odoo to=odoo-staging` (then neutralize mail/crons).
* list all of them in `UPGRADE_DB=odoo,odoo-staging` so boot upgrades hit each.

**Alternative — free-form db names (`dbfilter_from_header`):** keeps any db
name; the proxy maps host → filter via a request header (this replaces the old
host-nginx `proxy_set_header X-Odoo-dbfilter` vhost setup). Needs the module
in `server_wide_modules` (`base,web,dbfilter_from_header`), `PROXY_MODE=True`,
and a per-host Traefik `headers` middleware. Dokploy's Domains UI cannot attach
middlewares — use compose labels (note `$$` escapes `$` in compose):

```yaml
labels:
  - "traefik.http.middlewares.acme-dbf.headers.customrequestheaders.X-Odoo-Dbfilter=^AcmeProd$$"
  - "traefik.http.routers.acme.rule=Host(`acme.example.com`)"
  - "traefik.http.routers.acme.middlewares=acme-dbf"
  # + entrypoints/tls/service lines, and a second /websocket router per host
  #   with the SAME middleware (else live chat lands on the wrong db)
```

Prefer the subdomain scheme: nothing can strip it, no server-wide module, and
db names double as documentation. Use the header only where a rename is truly
impossible.

**Renaming a db to fit the scheme:** Odoo 19's manager UI has no rename
button, but the RPC service still has one — it renames the database **and**
its filestore in one call (`exp_rename`). It is gated by db management, so
temporarily set `LIST_DB=True`, redeploy, then:

```bash
curl -s https://odoo.example.com/jsonrpc -H 'Content-Type: application/json' -d '{
  "jsonrpc":"2.0","method":"call",
  "params":{"service":"db","method":"rename",
            "args":["<ADMIN_PASSWD>","OldName","odoo"]}}'
```

Set `LIST_DB=False` again and update `DB_NAME`/`DBFILTER`/`UPGRADE_DB`
references. Manual equivalent (odoo stopped):
`ALTER DATABASE "OldName" RENAME TO "odoo"` **plus**
`mv $DATA_DIR/filestore/OldName $DATA_DIR/filestore/odoo` — forget the second
and every attachment/asset 404s. Don't backup/restore just to rename (slowest
path, same result). Either way sessions are invalidated (users re-login) and
**already-emailed links embed the old db name — re-send open invitations**.

### Databases, the manager, and a test/staging instance

Odoo selects the database **before login**, and the setting is **global** — so
"admin sees all DBs, users see only one" is impossible within a single instance.
The web DB manager (`/web/database/manager`) is gated only by the master password
(`ADMIN_PASSWD`), and it's fully disabled when `LIST_DB=False`.

Recommended layout — **prod stays locked, a second app is your admin/test console:**

| | prod app | test / admin app |
|---|---|---|
| `DOMAIN` | odoo.example.com | test.example.com |
| `DB_NAME` | `False` | `False` |
| `DBFILTER` | `(?i)^%d$` (subdomain == db, see above) | `.*` (manager lists every DB) |
| `LIST_DB` | `False` (clean, no manager) | `True` (DB manager enabled) |
| `UPGRADE_DB` | `prod` | `test` |
| `WORKERS` | `2` | `0` (cheap) |

Prod users land on `odoo` with no picker and no manager exposed. The test app's
manager can create/backup/restore **all** DBs (including prod) when it points at
the same Postgres — protect it with a strong `ADMIN_PASSWD`.

**Cost of the second app is small, and you control it:**
- The `gemini-odoo18` image layers are **shared** on disk — not doubled.
- An idle Odoo uses ~0% CPU; the only real cost is ~250–350MB RAM at `WORKERS=0`.
- **Stop it in Dokploy when you're not testing → ~0 overhead.** Start on demand.

**Don't even need a second Odoo for DB *management*** — the CLI covers it:
```
make dblist                        # list all databases
make dbtest from=odoo to=test      # clone prod -> fresh test copy
make dbbackup db=odoo              # dump to ./backups
make dbrestore db=test file=...    # restore
make dbcreate db=foo               # create + init base + own modules
make dbdrop db=test                # drop
```
A second running Odoo is only worth it when you want to *click around* in test
data. After cloning prod into a test DB, neutralize outgoing mail / crons before
using it.

Sharing one Postgres between two Dokploy apps: give the test app no `db` service
and set `DB_HOST` to the prod Postgres over a shared Dokploy network — **or**
just let the test app run its own Postgres (~40MB, fully isolated, safer staging).

### Reproducible builds
Pin the base image by digest in `.env`:
```
ODOO_IMAGE=odoo@sha256:<digest>
```
Vendor module versions are pinned by the `_vendor` submodule commits. Bump them
deliberately with `make submodules && git add src/third_party_addons/_vendor`.

---

## How module automation works

The entrypoint manages databases via two env vars:

- **`INIT_DB`** — one-shot fresh database creation. Comma-separated list of db
  names. Each db gets `base` + `UPGRADE_MODULES` + `INSTALL_MODULES` installed,
  and the admin password set to `ODOO_ADMIN_PASSWORD`. Already-existing dbs are
  skipped. **Set it, deploy once, then clear it.**
- **`UPGRADE_DB`** — comma-separated list of dbs to run `-i` / `-u` on every
  boot. Missing dbs are **skipped with a warning** (never auto-created). Empty
  or `"False"` = skip all upgrades (fast restart).

`INSTALL_MODULES` runs `-i` (use once per fresh DB, then clear).

### `UPGRADE_MODULES` — three modes

| value | behaviour | boot cost |
|---|---|---|
| `auto` **(recommended)** | checksum-based: upgrade only addons whose files changed | seconds when nothing changed |
| `<comma list>` | upgrade exactly these modules | small, fixed |
| `all` | force-upgrade every installed module | full, **every** boot |
| empty | skip upgrades entirely | none |

**`auto`** runs `click-odoo-update` (from `click-odoo-contrib`, installed in the
image). It sha1-hashes every installed addon directory, stores the hashes in
`ir.config_parameter`, and upgrades only those that differ — then saves new
hashes *after* a successful run, so a failed upgrade retries rather than being
silently skipped. Odoo cascades an upgrade to dependent modules, and vendor
submodule bumps change file hashes, so both are caught automatically.

```bash
click-odoo-update -c "$ODOO_RC" -d <db>
```

It finds the changed modules with plain SQL and then runs the same registry
load as `odoo -u <changed modules>`. Nothing reads through the ORM before the
schema is synced, so a module that adds a stored field to a core model cannot
hit `column ... does not exist` on the way to the upgrade that adds that very
column. When nothing changed it upgrades nothing and only opens the database
once (about two seconds on a 149-module database).

The hashes are stored under the key OCA `module_auto_update` used
(`module_auto_update.installed_checksums`), so a database that ran on that
addon carries over without a full upgrade. `auto` no longer needs the addon.

There is **no `-u all` fallback**. If the upgrade of the changed modules fails,
the boot aborts rather than serving a half-upgraded database, and the next boot
retries. An upgrade that fails for the changed modules fails the same way under
`-u all`, only minutes later — see the decision record
`2026-10-02-auto-upgrade-click-odoo-update` in the product repo.

> First run on a database with no saved hashes upgrades **everything** — the
> tool deliberately errs toward safety. Subsequent boots are cheap.
> (`click-odoo-update --only-compute-hashes` can seed hashes without upgrading,
> but only when you are certain disk and DB are already in sync.)

> **A base image change upgrades most of the database.** When `ODOO_IMAGE`
> moves to a newer build of `odoo:19.0`, the hashes of the core addons change
> and the next boot upgrades them all — minutes, not seconds. Pin `ODOO_IMAGE`
> by digest (see *Reproducible builds*) so that happens only when you choose.

> A module that is **new on disk** shows up in Apps only after a boot that
> upgraded something, because Odoo refreshes its module list during an upgrade.
> Otherwise name it in `INSTALL_MODULES`, or use Apps → Update Apps List.

**`all`** has two sharp edges, both hit in practice: it costs the full upgrade
on *every* restart (there is no change detection — `load_data` re-runs for every
module regardless), and it dependency-checks every installed module, so a single
unmet python dep anywhere — including in a legacy module you no longer use —
raises `UserError` and blocks startup entirely.

`auto` and `all` are *modes*, not module names. The `INIT_DB` path drops both
from the install list. Name real modules in `INSTALL_MODULES` — splicing a mode into `-i` yields a dummy that Odoo
silently ignores, leaving a fresh db with `base` only.

Examples:
```bash
UPGRADE_MODULES=auto             # only what changed (recommended)
UPGRADE_MODULES=my_mod,other     # exactly these
UPGRADE_MODULES=all              # everything, every boot
UPGRADE_DB=UUs                   # upgrade one db every boot
UPGRADE_DB=UUs,UUs_Test          # upgrade multiple dbs
UPGRADE_DB=                      # skip upgrades entirely (fast restart)
INIT_DB=NewClient                # create a fresh db (one-shot, then clear)
```

### `LANG_NOUPDATE` — keep language settings across upgrades

Odoo ships its language defaults in `odoo/addons/base/data/res.lang.csv`, listed
in `base`'s `data`. CSV data files carry no `noupdate` flag, so they import with
`noupdate=False` and are **replayed on every `base` upgrade**. Since `-u all`
includes `base` — as does `auto` on its first pass and after a base image
change — a redeploy silently resets Settings → Translations → Languages:

```
date_format   %d.%m.%Y  ->  %m/%d/%Y
```

and likewise `time_format`, `decimal_point`, `thousands_sep`, `grouping` and
`week_start`. Nothing in the UI reports it, so it reads as a random redeploy
gremlin. It is not: it is `base` reasserting upstream defaults.

The entrypoint fixes this before each upgrade by setting `noupdate = true` on the
`res.lang` rows in `ir_model_data`. `models._load_records()` skips a record whose
external id is flagged `noupdate`, so the CSV re-import becomes a no-op **for
`res.lang` only** — every other module's data keeps updating as before. The step
is plain SQL (no registry load, so it cannot trip over a not-yet-applied schema)
and idempotent: it reports a count on the first boot and does nothing after.

On by default. The trade-off is that genuine upstream corrections to language
data stop landing too — that is the point, and it is the standard Odoo answer for
customised core data.

```bash
LANG_NOUPDATE=1                  # default: your language settings stick
LANG_NOUPDATE=0                  # opt out; take upstream's values on every -u base
```

Set the format once in the UI after the first boot with this enabled. It applies
to the dbs named in `INIT_DB` and `UPGRADE_DB`.

## Major-version upgrade (OpenUpgrade)

The image is built with OpenUpgrade baked in (build arg `OPENUPGRADE=1`,
compose var `OPENUPGRADE_BUILD`, default on): `openupgradelib` from git master
plus `openupgrade_framework` + `openupgrade_scripts` of the matching OCA
branch at `/opt/openupgrade`. It stays inert until a container boots with
env `OPENUPGRADE=1`. Then, for every database in `UPGRADE_DB` not yet marked
migrated, the entrypoint runs **once**:

1. `odoo -u all` with OpenUpgrade on the addons path, `--upgrade-path` to its
   scripts and `--load=base,web,openupgrade_framework` (the core migration).
2. A plain `odoo -u all` without OpenUpgrade. The framework downgrades view
   errors to `Can't render custom view` warnings, so step 1 exiting 0 proves
   nothing about the views; this pass fails loudly on them.
3. `odoo -i $INSTALL_MODULES`: `-u` never installs a dependency that is new in
   the new version of a module (e.g. `pdf_xml_attachment` for
   `account_invoice_import`); the module stays `to upgrade` until you list it.
4. Sets `ir.config_parameter` `platform.openupgrade_done` = series, so a
   restart with `OPENUPGRADE=1` still set skips the sequence.

Any failing step aborts the boot without the mark; the next boot retries.
Two full `-u all` passes outlast the default health-probe grace: set
`HEALTHCHECK_START_PERIOD=900s` (or more) for that deploy. Remove
`OPENUPGRADE=1` afterwards.

**Rehearse first, on a neutralized copy, offline.** From the new-series
checkout (own `.env`: own `COMPOSE_PROJECT_NAME`, image name, a fresh
`ENCRYPTION_KEY` — never production's):

```bash
platform/scripts/rehearse-upgrade.sh /path/to/odoo_<date>.zip
```

It restores the backup, runs the product's `tools/neutralize_db.sql` (aborts
unless its VERIFY block is clean) and `odoo neutralize` before any Odoo
process touches the data, runs the entrypoint sequence above in one container,
probes each not-yet-ported module on a throwaway copy, prints module states
against the backup's `manifest.json`, and leaves the stack up at
`http://localhost:$REHEARSAL_PORT`. Everything runs with
`platform/docker-compose.rehearsal.yml`: db + odoo on an `internal` network
(no egress), a socat gateway publishes the UI on 127.0.0.1 only.
`ADDONS_SKIP_UNPORTED=1` (rehearsal/port stacks only, never production) keeps
modules whose manifest version is not yet of the image's series off the
addons path, so they neither break the run nor lose their data: they stay
`to upgrade` until ported.

## Health probe

The `odoo` service reports a real health status to `docker ps`. It is deliberately
not the obvious probe, because the two obvious probes both lie.

| endpoint | broken registry | broken ORM |
|---|---|---|
| `/web/health` | **200 pass** | **200 pass** |
| `/web/login` | **200** (no-db fallback) | **200** |
| `/web/manifest.webmanifest` | 404 | 500 |

`/web/health` is `auth='none'` and returns `{"status": "pass"}` unconditionally;
`?db_server_status=1` only opens a cursor on the `postgres` maintenance database.
`/web/login` is worse: when the registry is unusable Odoo catches `RegistryError`
and re-serves through `_serve_nodb()`, rendering a healthy-looking login form
backed by no database. Both report success during an outage where every ORM read
fails.

So the probe uses an `auth='public'` route. `_serve_nodb()` dispatches against
`nodb_routing_map`, which holds only `auth='none'` routes — a public route is
absent and 404s rather than degrading quietly. Binding the public user also reads
`res.users` → `res.partner`, the query shape that real schema drift breaks.

Logic lives in `platform/docker/healthcheck.py` (uses `python3`; the image has no
`curl`). Knobs:

| var | default | notes |
|---|---|---|
| `HEALTHCHECK_START_PERIOD` | `300s` | must outlast the boot upgrade; failures inside it don't count |
| `HEALTHCHECK_START_INTERVAL` | `5s` | probe cadence inside the start period — Traefik sends no traffic until the first pass; needs Docker Engine 25+ |
| `HEALTHCHECK_INTERVAL` | `30s` | |
| `HEALTHCHECK_RETRIES` | `3` | |
| `HEALTHCHECK_TIMEOUT` | `10` | seconds, script-side; keep below compose's `timeout: 15s` |
| `HEALTHCHECK_HOST` | falls back to `DB_NAME` | only needed when `DB_NAME=False` — see below |
| `HEALTHCHECK_PATH` | `/web/manifest.webmanifest` | keep it `auth='public'` or stricter |
| `HEALTHCHECK_DISABLE` | unset | `1` turns the probe into a no-op |

> **Host selection.** The probe talks to `127.0.0.1`, and `db_filter()` reduces
> that to `%d` = `"127"` — matching no database, so a host-routed `DBFILTER`
> would serve db-less and the probe would report a *false* failure. To avoid
> that it sends `Host: $DB_NAME` by default. `%d` is only the first label of the
> Host and is never resolved as a name, so the bare db name is a valid Host; it
> is also harmless under a fixed `DBFILTER` (`^mydb$`), which ignores the host.
>
> Only **multi-db** (`DB_NAME=False`) needs `HEALTHCHECK_HOST` set explicitly —
> there is no single database to infer. Left unset with a `%d`/`%h` filter, the
> probe logs why it cannot select one instead of looking like an outage.

An unhealthy container is **not** restarted — Docker only reports the status.
Acting on it (alerting, rollback) is not built yet: see
[odoo-platform#2](https://github.com/T-Altendorf/odoo-platform/issues/2).

## Secrets at rest (`RUNNING_ENV` / `ENCRYPTION_KEY`)

Modules holding third-party credentials (API keys, PSD2 signing keys) should not
keep them readable in the database — a dump, a backup or a replica would carry
them along. The OCA `data_encryption` module (from `OCA/server-env`) stores such
values as Fernet ciphertext in its `encrypted.data` model, with the key read
from `odoo.conf` rather than from any table.

The entrypoint renders that config for you:

```bash
RUNNING_ENV=prod                 # names the key set
ENCRYPTION_KEY=<fernet key>      # 32-byte urlsafe-base64
```

which becomes `running_env = prod` plus `encryption_key_prod = …` appended to
`$ODOO_RC`. Two environments can therefore hold different secrets against the
same codebase — restoring a prod dump into staging leaves the ciphertext
undecryptable there, which is the point.

Generate a key with:

```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

It must be a real Fernet key, not a passphrase — `data_encryption` feeds the
value straight to `Fernet()`.

> **Keep the key in a password manager, not only in `.env`.** Losing it makes
> every stored secret permanently unreadable; there is no recovery path.

Both variables are optional. Setting neither leaves secrets in cleartext and the
entrypoint says so at boot. Setting `ENCRYPTION_KEY` without `RUNNING_ENV` is a
hard error rather than a silent fallback — a half-configured key would otherwise
look like it worked while still storing plaintext. `$ODOO_RC` is `chmod 600`
since it now carries the key alongside `db_password` and `admin_passwd`.

## Backups (nightly, encrypted, off-site)

The `backup` service is a small container beside `db` and `odoo`. It does not
need Odoo. Each night it does this for every database in `BACKUP_DBS`:

1. Make one Odoo backup zip, in the same format as the **Backup** button of
   the Odoo database manager (`/web/database/manager`): `dump.sql` (plain SQL,
   `pg_dump --no-owner`), `filestore/` (the filestore of the database) and
   `manifest.json` (Odoo series, Postgres version, installed modules).
2. Encrypt the zip with [`age`](https://age-encryption.org) and your
   **public** key before it leaves the container. The server holds no key
   that can decrypt a backup.
3. Upload by SFTP as `<db>_<UTC stamp>.zip.age.part`, then rename it to
   `<db>_<UTC stamp>.zip.age`. One file per database and run. A `.part` file
   is an upload that did not finish; it is not a backup. age authenticates
   the file: a damaged or cut file does not decrypt, so there is no checksum
   file.
4. Only when all uploads worked: delete the remote files of these databases
   that are older than `BACKUP_KEEP_DAYS` (this includes the 3-file sets
   `.dump.age`, `.filestore.tar.gz.age`, `.sha256` of the format before
   October 2026), and `.part` files older than one day.
5. Tell the monitor: `BACKUP_PING_URL/start` at the start, `BACKUP_PING_URL` on
   success, `BACKUP_PING_URL/fail` on failure. The exit code is not 0 on failure
   and the container log names the failed step.

All files are in `platform/backup/` (image). The services `backup` and
`backup-restore` are in `platform/docker-compose.yml`. The `backup` service
starts with every stack. When `BACKUP_DBS` is empty, it writes one line,
`backup: off, BACKUP_DBS is not set`, and does nothing more. Set the
`BACKUP_*` variables to turn the nightly job on. `backup-restore` is in the
profile `restore`: `up` does not start it, `docker compose run backup-restore`
does. There is no overlay file and no profile for the nightly job: Dokploy runs
`docker compose -p <app> --env-file .env -f <Compose Path> up -d --build`
with exactly one `-f`, so it ignores `COMPOSE_FILE`, and it does not apply
`COMPOSE_PROFILES`. Keep the Compose Path `./docker-compose.yml`.

### Setup (one time)

1. **Make the key pair on your own computer, not on the server.**

   ```bash
   brew install age            # or: apt install age
   age-keygen -o age-key.txt   # prints "Public key: age1..."
   ```

   Put the full contents of `age-key.txt` in the password manager, then delete
   the file. Without this private key nobody can read a backup. There is no
   recovery path. The public key (`age1...`) is not a secret.
2. **Get the host key of the SFTP server** (one line):

   ```bash
   ssh-keyscan -t ed25519 sftp.example.com     # add -p PORT if not 22
   ```

   If the server has no ed25519 key, the command prints only a `#` line. Then
   remove `-t ed25519` and use the one key line that it prints (for example
   `ssh-rsa`). With a port that is not 22 the line starts with
   `[host]:PORT`; keep it like that. Compare it with the fingerprint that the
   provider shows (`ssh-keygen -lf <file>`), then use the full line as
   `BACKUP_SFTP_HOST_KEY`. The backup refuses a server with another key.
3. **Make the remote directory** (`BACKUP_SFTP_DIR`). The backup does not make it.
4. **Make a check on a ping monitor** (for example healthchecks.io: period
   1 day, grace 2 hours, alert by mail). Use its URL as `BACKUP_PING_URL`. The
   monitor also alerts when no backup started at all (server down, container
   gone). A mail from the container cannot do that.
5. **Set the environment** (Dokploy → Environment, or `.env`). Never put these
   values in git or in the database:

   | Variable | Example | Meaning |
   |---|---|---|
   | `BACKUP_DBS` | `odoo` | database names, separated by spaces. Empty = backup off |
   | `BACKUP_AGE_RECIPIENT` | `age1...` | the public key |
   | `BACKUP_SFTP_HOST`, `BACKUP_SFTP_PORT` | `sftp.example.com`, `22` | target server |
   | `BACKUP_SFTP_USER`, `BACKUP_SFTP_PASSWORD` | | login. Leave the password empty to use an SSH key mounted at `/root/.ssh` |
   | `BACKUP_SFTP_DIR` | `backups/odoo` | remote directory, must exist |
   | `BACKUP_SFTP_HOST_KEY` | `sftp.example.com ssh-ed25519 AAAA...` | the line from step 2 |
   | `BACKUP_KEEP_DAYS` | `50` (default) | delete remote files older than this |
   | `BACKUP_SCHEDULE` | `30 2 * * *` (default) | cron expression, **UTC** |
   | `BACKUP_PING_URL` | `https://hc-ping.com/<uuid>` | monitor URL from step 4 |

   The database login comes from `DB_USER` / `DB_PASSWORD`.
6. **Deploy, then run one backup by hand** and look at the result:

   ```bash
   docker compose exec backup backup.sh        # or the Dokploy terminal of `backup`
   docker exec <project>-backup-1 backup.sh    # on the host; <project> = Dokploy app name
   ```

   The last line must be `backup: OK <stamp>`, the file
   `<db>_<stamp>.zip.age` must be on the SFTP server, and the monitor must
   show a success.

If `BACKUP_DBS` is set and another required variable is missing, the `backup`
container stops at start with `backup: ERROR: <NAME> is not set` and restarts
in a loop. `BACKUP_PING_URL` is optional; without it the log shows a warning.
The container needs free disk space in `/tmp` for about two copies of the
zip: the plain `dump.sql` and the zip, then the zip and its encrypted copy.
The files of one database are deleted before the next database starts.

### What is NOT in the backup

- **The environment.** `ENCRYPTION_KEY`, `RUNNING_ENV`, `DB_PASSWORD`,
  `ADMIN_PASSWD`, the `BACKUP_*` values and API keys live in Dokploy only.
  Without `ENCRYPTION_KEY` the restored database cannot decrypt its stored
  secrets (for example the Enable Banking key). **Keep a copy of the full
  Dokploy environment in the password manager** and update it when it changes.
- The private age key (password manager only).
- Databases that are not in `BACKUP_DBS`, Postgres roles, Odoo sessions.
- The code. It is in git.

### Restore runbook

A backup counts only after one restore worked. Do a restore test after the
setup and again after each major change.

Do the test **on your own computer or on a staging stack, not on production**:
a restored copy of production still has active crons, mail servers and bank
connections. If the copy must be on a server where Odoo runs, stop the `odoo`
service first.

1. Use a checkout of the product repo with the same `BACKUP_SFTP_*` values in
   `.env`. Start only the database: `docker compose up -d db`.
2. Write the private key from the password manager to a file, for example
   `~/age-key.txt` (`chmod 600`).
3. Restore. `latest` is the newest backup; a stamp such as
   `20261024T023000Z` selects one backup:

   ```bash
   docker compose run --rm -v ~/age-key.txt:/age-key.txt:ro \
     backup-restore <source_db> latest <target_db>
   ```

   The script downloads `<source_db>_<stamp>.zip.age`, decrypts it (a wrong
   key or a damaged file stops here), makes the database `<target_db>` (UTF8,
   collation C, as Odoo does), loads `dump.sql` with `psql`, and unpacks the
   filestore to `/var/lib/odoo/filestore/<target_db>`. It never overwrites: it
   stops if the database or the filestore directory exists.

   **Or restore in the Odoo database manager.** Decrypt the backup to a
   normal Odoo backup zip, then use **Restore Database** at
   `/web/database/manager` (master password; for a test copy tick
   **This database is a copy** and **Neutralize**):

   ```bash
   docker compose run --rm -T -v ~/age-key.txt:/age-key.txt:ro \
     backup-restore <source_db> latest --zip-only > backup.zip
   ```

   `-T` is necessary: the zip goes to stdout. Without Docker, the same with
   `age` only: download the `.zip.age` file by SFTP, then
   `age -d -i ~/age-key.txt -o backup.zip <file>.zip.age`.
4. Delete `~/age-key.txt`.
5. **Test copy:** neutralize it before Odoo starts on it (the product's
   `tools/neutralize_db.sql`). **Real recovery:** do not neutralize; set the
   environment from the password manager (`ENCRYPTION_KEY`, `RUNNING_ENV`, ...)
   and use the production database name as `<target_db>`.
6. Start Odoo, log in, open one attachment (filestore) and one record with a
   stored secret (for example Enable Banking → Check Connection in a real
   recovery).

### Test the scripts

```bash
platform/scripts/test-backup-restore.sh
```

It needs only Docker. It starts a throwaway Postgres, SFTP server and ping
receiver, makes an Odoo database with `ODOO_IMAGE` (default `odoo:19.0`; give
the product image to skip the pull), then checks: the backup (one `.zip.age`
file), retention (old files, old 3-file sets, stale `.part` files), the
failure ping, `--zip-only` (zip contents, `manifest.json`, and a restore with
Odoo's own `restore_db()`, the code behind the database manager's Restore), a
restore with a wrong key, a restore with the right key (table checksum and
file checksums equal), and that a second restore does not overwrite. Run it
after each change in `platform/backup/`.

## Python requirements
The image installs, at build time:
- every `third_party_addons/{_vendor,_static_vendor}/*/requirements.txt`
- the repo-root `requirements.txt` (own/custom extras)

Set build arg `INSTALL_VENDOR_REQS=0` for a slim image and curate
`requirements.txt` yourself. `_static_vendor` modules have no requirements file
today — add their deps to the root `requirements.txt` (or drop one beside the
copied module).
