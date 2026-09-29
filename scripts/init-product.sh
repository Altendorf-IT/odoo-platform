#!/usr/bin/env bash
# Scaffold a brand-new Odoo product ("tenant") repo around this platform.
#
#   bash scripts/init-product.sh <product-name> [target-dir]
#
# Creates a git repo that consumes odoo-platform as a submodule at platform/,
# with the enforced src/ layout (custom_addons + third_party_addons) and all
# thin config files. After it finishes you only: add vendor submodules, list
# them in selection.txt, `make selection`, create the GitHub repo, push.
#
# PLATFORM_URL env overrides the platform remote (defaults to this repo's
# origin, else the canonical T-Altendorf URL).
set -euo pipefail

NAME="${1:?usage: init-product.sh <product-name> [target-dir]}"
TARGET="${2:-$NAME}"

# Resolve the platform remote to add as a submodule.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${PLATFORM_URL:-}" ]; then
    PLATFORM_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
    PLATFORM_URL="${PLATFORM_URL:-https://github.com/T-Altendorf/odoo-platform.git}"
fi

[ -e "$TARGET" ] && { echo "ERROR: $TARGET already exists — refusing to overwrite" >&2; exit 1; }

echo "==> scaffolding '$NAME' in $TARGET (platform: $PLATFORM_URL)"
mkdir -p "$TARGET"
cd "$TARGET"
git init -q

# --- platform submodule ------------------------------------------------------
git submodule add -q "$PLATFORM_URL" platform
echo "    added platform submodule"

# --- enforced src/ skeleton --------------------------------------------------
mkdir -p src/custom_addons \
         src/third_party_addons/_vendor \
         src/third_party_addons/_static_vendor \
         src/third_party_addons/_selected
# .gitkeep so the empty category dirs survive the commit.
touch src/custom_addons/.gitkeep \
      src/third_party_addons/_vendor/.gitkeep \
      src/third_party_addons/_static_vendor/.gitkeep \
      src/third_party_addons/_selected/.gitkeep

# --- thin config files -------------------------------------------------------
# --- docs/decisions + AGENTS.md ----------------------------------------------
# Decision records are mandatory (see platform/README.md "Decision records").
# The docs README is a product-owned COPY (the product edits its index);
# AGENTS.md is a SYMLINK so platform bumps keep agent rules current everywhere.
mkdir -p docs/decisions
cp "$SCRIPT_DIR/../templates/docs-README.md" docs/README.md
touch docs/decisions/.gitkeep
ln -s platform/AGENTS.md AGENTS.md
echo "    added docs/decisions + AGENTS.md"

# Root compose is a SYMLINK to the platform stack — NOT an `include:` wrapper.
# Dokploy's domain UI parses the compose statically and does not expand
# `include:`, so a wrapper hides the services ("service odoo does not exist").
# A symlink exposes the real services at the repo root while keeping project-dir
# at the root, so build paths (context: .) and the root .env that Dokploy writes
# both resolve correctly. See platform/DEPLOY.md "Root compose is a symlink".
ln -s platform/docker-compose.yml docker-compose.yml

cat > Makefile <<YAML
# Product config only — every target lives in the odoo-platform submodule.
# \`make help\` for the list; see platform/README.md for the integration contract.
OWN_MODULES ?=

include platform/Makefile
YAML

cat > selection.txt <<'TXT'
# Vendor modules this product loads. Paths relative to src/third_party_addons/.
# After editing:  make selection   (regenerates _selected symlinks; commit them)
# Every module also needs a why-line in selection_reasons.md (pre-commit
# enforced; `make selection` appends the stubs).
# Rules: see platform/README.md — never put _vendor/_static_vendor on addons_path.

# _vendor/oca_knowledge/document_page
# _static_vendor/auto_database_backup
TXT

# selection_reasons.md — one why-line per loaded module, enforced by the
# pre-commit hook. `make selection` creates stubs; humans write the reasons.
bash platform/scripts/selection-reasons.sh --sync

# Commit-time checks (layout + documented selection) for every clone of this
# repo. core.hooksPath is per-clone config, so the README tells clones to
# re-run `make hooks`.
git config core.hooksPath platform/githooks
echo "    installed pre-commit checks (make hooks)"

cat > requirements.txt <<'TXT'
# Extra python deps for this product's OWN modules. Vendor deps are installed
# automatically from src/third_party_addons/{_vendor,_static_vendor}/*/requirements.txt.
TXT

cat > .env.example <<TXT
# Copy to .env and adjust. Everything Odoo needs lives here.
#   cp .env.example .env

# --- Odoo base image ---------------------------------------------------------
ODOO_IMAGE=odoo:19.0
INSTALL_VENDOR_REQS=1
IMAGE_NAME=${NAME}
IMAGE_TAG=latest

# --- Database ----------------------------------------------------------------
# Postgres tuning (defaults assume ~8GB RAM for Postgres; scale to the server:
# shared_buffers ~= 25% of Postgres RAM, effective_cache_size ~= 50-75%).
# PG_SHARED_BUFFERS=2GB
# PG_EFFECTIVE_CACHE_SIZE=6GB
# PG_WORK_MEM=32MB
# PG_MAINTENANCE_WORK_MEM=256MB
# PG_MAX_CONNECTIONS=100
#
# Container memory ceiling for Postgres. Set it on every shared host: without a
# limit the kernel OOM killer, not Docker, decides who dies when the box runs
# out — and it may pick this postmaster over the process that caused the spike.
# DB_MEM_LIMIT=2g
#
# dynamic_shared_memory_type. Defaults to \`sysv\`, which keeps the DSM control
# segment in kernel IPC. Under Postgres's own \`posix\` default it is a file in
# /dev/shm, and if that file is removed while the postmaster keeps running,
# EVERY new connection fails with
#   FATAL: could not open shared memory segment "/PostgreSQL.<n>"
# until Postgres is restarted — it cannot recover on its own, and disabling
# parallel query does not help (the control segment exists regardless). Only
# revert to posix if sysv hits a kernel shmall/shmmax limit.
# PG_DYNAMIC_SHARED_MEMORY_TYPE=sysv
# PG_SHM_SIZE=256mb                      # /dev/shm size; only used under posix
# PG_MAX_PARALLEL_WORKERS_PER_GATHER=0   # Odoo gains little from parallel query
DB_USER=odoo
DB_PASSWORD=change-me-db
# Single-db: set DB_NAME=<db> (entrypoint derives DBFILTER=^<db>$, host ignored).
# Multi-db (e.g. prod + staging in one stack): DB_NAME=False + DBFILTER below.
DB_NAME=False
# Host -> db routing. REQUIRED when DB_NAME=False and more than one db exists:
# a fresh session (emailed /web/signup and /web/reset_password links!) only
# gets a db when EXACTLY ONE db matches the filter — with the .* fallback and
# 2+ dbs those links 404. Standard scheme: subdomain == db name, ignoring case:
#   odoo.example.com -> db "odoo", odoo-staging.example.com -> db "odoo-staging",
#   altendorfit.example.com -> db "AltendorfIT" (no rename for case mismatches;
#   don't keep two dbs differing only by case). %d = first DNS label of the
# request host. Alternative for free-form db names (dbfilter_from_header +
# per-host Traefik header): platform/DEPLOY.md "Host -> database routing".
# DBFILTER=(?i)^%d$
LIST_DB=False
DB_EXPOSE_PORT=5432

# --- Odoo server -------------------------------------------------------------
ADMIN_PASSWD=change-me-admin
ODOO_ADMIN_PASSWORD=admin
HTTP_PORT=8069
GEVENT_PORT=8072
PROXY_MODE=True
WORKERS=2
MAX_CRON_THREADS=1
DB_MAXCONN=16
LOG_LEVEL=info

# --- Limits ------------------------------------------------------------------
# Platform defaults live in platform/docker-compose.yml; uncomment to tune.
#
# The connection budget is a straight sum and must hold:
#   (WORKERS + MAX_CRON_THREADS + 1) * DB_MAXCONN  <=  PG_MAX_CONNECTIONS
#
# Memory is NOT a straight sum. Odoo loads the registry in the master and then
# forks, so workers share those pages copy-on-write and a cgroup counts them
# once: real usage sits far below WORKERS * LIMIT_MEMORY_SOFT. Reconcile
# ODOO_MEM_LIMIT with the host's RAM and let the per-worker limits be ceilings.
#
# LIMIT_MEMORY_SOFT does the real work: past it the worker finishes its request
# and exits, and the master respawns it. It has a FLOOR — because psutil counts
# shared pages, a newborn worker already reports the master's full RSS
# (~500-700MB with a large addons set). Set SOFT under that and every worker
# dies before its first request, looping on
#   Worker (<pid>) alive / virtual memory limit reached / exiting, request_count: 0
# (the message says "virtual memory" but prints VMS while comparing RSS).
# Check the floor with \`docker stats --no-stream\` before lowering it.
#
# LIMIT_MEMORY_HARD is an RLIMIT_AS crash guard on virtual address space, which
# sits well above RSS, so keep it loose — too tight and large PDF/xlsx exports
# die with MemoryError. LIMIT_REQUEST recycles on request count and catches slow
# leaks that never trip SOFT; never set it to an effectively-infinite value,
# that just disables recycling.
#
# WORKERS must be >= 2 whatever the memory pressure: wkhtmltopdf calls back into
# Odoo over HTTP, so a single worker deadlocks every PDF report.
#LIMIT_MEMORY_SOFT=1342177280    # 1.25 GiB
#LIMIT_MEMORY_HARD=2684354560    # 2.5 GiB
#LIMIT_REQUEST=8192
#LIMIT_TIME_CPU=300
#LIMIT_TIME_REAL=600
#ODOO_MEM_LIMIT=3g

# --- Module automation -------------------------------------------------------
UPGRADE_DB=
UPGRADE_MODULES=
INSTALL_MODULES=
INIT_DB=
# Keep Settings > Translations > Languages (date format, separators, week start)
# across upgrades. base ships those defaults in a CSV data file with no noupdate
# flag, so every -u base resets them. On by default; 0 tracks upstream instead.
# See DEPLOY.md "LANG_NOUPDATE".
#LANG_NOUPDATE=1

# --- Health probe ------------------------------------------------------------
# Sane defaults are baked into platform/docker-compose.yml; uncomment to tune.
# Raise START_PERIOD if the boot upgrade regularly takes longer than 5 min.
# HEALTHCHECK_HOST is ONLY needed when DBFILTER routes by host (%d) — see
# DEPLOY.md "Health probe".
#HEALTHCHECK_START_PERIOD=300s
#HEALTHCHECK_INTERVAL=30s
#HEALTHCHECK_HOST=
#HEALTHCHECK_DISABLE=

# --- Debugger (dev only) -----------------------------------------------------
DEBUG=0
DEBUGPY_PORT=5678
DEBUGPY_WAIT=

# --- Domain ------------------------------------------------------------------
# One subdomain per database (see DBFILTER above). Every host needs BOTH
# Dokploy domain entries (\`/\` -> 8069 and \`/websocket\` -> 8072) or the Traefik
# labels in platform/docker-compose.yml.
DOMAIN=odoo.example.com
# staging db "odoo-staging" would be served at odoo-staging.example.com
TXT

cat > .gitignore <<'TXT'
# Local dev config (per-machine, never committed)
/odoo.conf
.env
*.code-workspace

# Personal .vscode scratch, but share the dev debugger setup
.vscode/*
!.vscode/launch.json
!.vscode/tasks.json
!.vscode/extensions.json

# Python / OS
__pycache__/
*.py[cod]
.DS_Store

# Local backups
/backups/
TXT

cat > README.md <<TXT
# ${NAME} — Odoo 19 Product Repo

Content-only repo (first-party modules + vendor selection + deploy config).
All deployment machinery lives in the [odoo-platform](${PLATFORM_URL%.git})
submodule at \`platform/\`. See **[platform/README.md](platform/README.md)**.

## Layout (enforced by \`make check\`)
\`\`\`
src/
├── custom_addons/        <-- your first-party modules (on addons_path)
└── third_party_addons/
    ├── _vendor/          <-- vendor submodules      (NEVER on addons_path)
    ├── _static_vendor/   <-- committed snapshots     (NEVER on addons_path)
    └── _selected/        <-- generated symlinks (the ONLY vendor dir loaded)
\`\`\`

## Quick start
\`\`\`bash
# fresh clone: activate the commit-time checks once
make hooks

# add a vendor repo, then pick its modules
git submodule add -b 19.0 https://github.com/OCA/knowledge.git src/third_party_addons/_vendor/oca_knowledge
echo "_vendor/oca_knowledge/document_page" >> selection.txt
make selection            # build _selected symlinks (commit them)
                          # + stubs a why-line in selection_reasons.md — write it,
                          # pre-commit fails on missing/TODO entries

cp .env.example .env      # then edit secrets
make up                   # dev stack (ports, live mount, reload)
\`\`\`

## Decision records (mandatory)

Any change to what this product does (module selection, workflow design,
infrastructure) gets a dated record in \`docs/decisions/\` — written **in the
same commit/PR as the change**. Convention + index: [docs/README.md](docs/README.md);
rationale: platform/README.md "Decision records". AI agents follow the same
rule via [AGENTS.md](AGENTS.md) (symlink into the platform).

## Updating vendor submodules
\`\`\`bash
make submodules           # bump every _vendor submodule to latest upstream
\`\`\`
Submodules pinned to SSH URLs for deploy auth (see platform/DEPLOY.md
"Private submodules & Dokploy auth", pattern B) fail on dev machines that use
\`gh\` over HTTPS. \`make submodules\` handles this via \`make dev-remotes\`,
which rewrites them to HTTPS in local git config only — \`.gitmodules\` keeps
SSH for deploy. One-time prerequisite: \`gh auth setup-git\`.
TXT

# --- submodule watcher workflow ----------------------------------------------
# Daily PR that bumps every submodule to its tracked-branch tip (logic lives in
# platform/.github/workflows/bump-submodules.yml). Merge = ship, close = veto;
# fail-soft skips any submodule it can't fetch. Requires a SUBMODULE_BUMP_PAT
# repo secret (see that workflow's header). Scheduled runs only fire from the
# repo's DEFAULT branch.
PLATFORM_SLUG="$(printf '%s' "$PLATFORM_URL" | sed -E 's#(git@github.com:|https?://github.com/)##; s#\.git/?$##')"
mkdir -p .github/workflows
cat > .github/workflows/watch-submodules.yml <<YAML
name: Watch submodules
on:
  schedule:
    - cron: "17 3 * * *"   # once a day
  workflow_dispatch:
jobs:
  bump:
    uses: ${PLATFORM_SLUG}/.github/workflows/bump-submodules.yml@19.0
    secrets:
      BUMP_TOKEN: \${{ secrets.SUBMODULE_BUMP_PAT }}
YAML
echo "    added .github/workflows/watch-submodules.yml"

# --- verify + first commit ---------------------------------------------------
echo "==> verifying layout"
bash platform/scripts/check-layout.sh

git add -A
git commit -q -m "Scaffold ${NAME} around odoo-platform submodule"
echo "    committed initial scaffold"

cat <<EOF

Done. '${NAME}' scaffolded in $TARGET

Next:
  1. cd $TARGET
  2. Put first-party modules in src/custom_addons/
  3. Add vendor repos: git submodule add -b 19.0 <url> src/third_party_addons/_vendor/<name>
     then list modules in selection.txt and run: make selection
     (then write the why-lines it stubs into selection_reasons.md)
  4. Set OWN_MODULES in the Makefile
     (and from now on: every behavior change ships with a docs/decisions/
     record in the same commit — see docs/README.md)
  5. Create the GitHub repo and push:
       gh repo create <owner>/${NAME} --private --source=. --remote=origin --push
  6. Point Dokploy at it (recursive submodule clone + private-repo auth).
  7. Add the SUBMODULE_BUMP_PAT repo secret so the daily submodule-watcher
     runs (fine-grained PAT: Contents r/w + Pull requests r/w on this repo,
     Contents read on any private submodule repos). See
     .github/workflows/watch-submodules.yml.
EOF
