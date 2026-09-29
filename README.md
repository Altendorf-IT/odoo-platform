# odoo-platform

Shared Odoo 19 deployment machinery — Docker image, compose stack, entrypoint,
dev/ops Makefile, and the module-selection generator. Maintained **once** here;
consumed by every product repo as a **git submodule at `platform/`**.

A *product repo* owns only its content:

```
product-repo/
├── platform/                  <-- THIS repo (submodule)
├── docker-compose.yml         <-- symlink -> platform/docker-compose.yml (see DEPLOY.md)
├── AGENTS.md                  <-- symlink -> platform/AGENTS.md (AI-agent rules)
├── docs/                      <-- dated decision records (mandatory, see below)
├── Makefile                   <-- 2 lines (config + include, below)
├── selection.txt              <-- which vendor modules to load
├── requirements.txt           <-- extra python deps for own modules
├── .env / .env.example        <-- deployment config + secrets
├── .gitmodules                <-- the product's OWN vendor submodules
└── src/                      <-- EXACTLY two dirs (enforced by `make check`):
    ├── custom_addons/         <-- first-party modules (on addons_path)
    │   ├── my_module_a/
    │   └── my_module_b/
    └── third_party_addons/    <-- everything vendored
        ├── _vendor/           <-- submodules (NEVER on addons_path)
        ├── _static_vendor/    <-- committed snapshots (NEVER on addons_path)
        └── _selected/         <-- generated symlinks (the ONLY vendor dir on addons_path)
```

Only `src/custom_addons/` and `src/third_party_addons/_selected/` are on
`addons_path`. A module placed directly under `src/` (or anywhere else) will not
load — keep first-party modules in `custom_addons/`. `make check` enforces this.

## New product in one command

```bash
git clone https://github.com/T-Altendorf/odoo-platform.git
bash odoo-platform/scripts/init-product.sh my_tenant   # -> ./my_tenant
```

Creates a ready-to-run product repo: platform added as a submodule, the enforced
`src/` skeleton, and all thin config below (`docker-compose.yml`, `Makefile`,
`selection.txt`, `.env.example`, `.gitignore`, `README.md`), committed. It prints
the remaining steps (add vendor submodules, `make selection`, create + push the
GitHub repo, point Dokploy at it). The rest of this section is what that script
automates, for reference.

## Integration (once per product repo)

```bash
git submodule add https://github.com/T-Altendorf/odoo-platform.git platform
```

**docker-compose.yml** (product root — this is what Dokploy deploys):

```yaml
include:
  - path: platform/docker-compose.yml
    project_directory: .
```

**Makefile** (product root):

```make
OWN_MODULES ?= my_module_a,my_module_b
include platform/Makefile
```

**selection.txt** (product root) — one module per line, path relative to
`src/third_party_addons/`:

```
_vendor/oca_knowledge/document_page
_vendor/my_private_addon_repo/my_module
_static_vendor/auto_database_backup
```

Then `make selection` regenerates `src/third_party_addons/_selected/` (relative
symlinks, stale links pruned) — **commit the symlinks**; deploys and fresh
clones need no build step.

## Documenting the selection (selection_reasons.md)

Every module a product loads — vendor modules from `selection.txt` **and**
first-party modules in `src/custom_addons/` — needs a one-line reason in the
product's `selection_reasons.md`:

```
- `module_name` — why this product needs it.
```

Group the entries **by concern** (bank sync, invoicing, UI, …), not by vendor
repo — the file answers "what does our stack do and why", the vendor is
visible in `selection.txt` anyway. The workflow is automated at both ends:

* `make selection` appends a `TODO` stub for every undocumented module into
  the file's marked "unsorted" section (creating the file on first run). Move
  each stub to its concern section and replace the TODO with the reason.
* The pre-commit hook (`make hooks`, once per clone; `init-product.sh` does it
  for the scaffold clone) runs `scripts/selection-reasons.sh --check` and
  **fails the commit** while any loaded module is missing or still TODO.
  `make reasons` runs the same check on demand.

## Decision records (docs/decisions — mandatory)

Every product repo keeps dated decision records under `docs/decisions/`
(scaffolded by `init-product.sh` from `templates/docs-README.md`). Whenever a
change alters *what the product does* — module selection, workflow design,
infrastructure, integration behavior — a record
`docs/decisions/YYYY-MM-DD-short-slug.md` is written **in the same commit (or
PR) as the change**. This is a practice we always follow, not an option.

- Structure loosely as: **Context**, **Findings**, **Decision** (incl.
  rejected alternatives), **Consequences / follow-ups**.
- Index every record in `docs/README.md`.
- Never rewrite old records — add a new one and link back; a superseded
  record still explains why the old state existed.
- `selection_reasons.md` answers *what* is loaded and why in one line;
  decision records hold the *reasoning and rejected alternatives* behind
  those lines and everything else.

Platform changes that alter behavior get their record in the affected
product repo(s) — this repo stays product-agnostic machinery.

AI coding agents are bound to this practice (and to the shared working
rules) via [AGENTS.md](AGENTS.md), which every product repo exposes at its
root as a symlink to `platform/AGENTS.md`.

## Keeping submodules fresh (auto-bump PRs)

`init-product.sh` also drops in `.github/workflows/watch-submodules.yml`, a
thin caller of the reusable workflow here
(`.github/workflows/bump-submodules.yml`). Once a day it checks **every**
submodule in the product's `.gitmodules` against the tip of its tracked branch
(the `branch =` line) and, if any moved, force-pushes one fixed branch and
opens — or refreshes — a **single PR**. Merging that PR is what ships the
update; closing it is a veto. No PR spam; new upstream commits just refresh the
same PR. It is **fail-soft**: a submodule it can't fetch (a private repo the
token can't reach, or a network blip) is skipped with a warning, not fatal.

To activate it in a product repo:

1. Add a repo secret **`SUBMODULE_BUMP_PAT`** — a fine-grained PAT with
   *Contents: read+write* and *Pull requests: read+write* on the product repo,
   plus *Contents: read* on any **private** submodule repos you want bumped.
   Public submodules (OCA etc.) need no extra grant.
2. Make sure the workflow file is on the repo's **default branch** — scheduled
   runs only fire from there. Use the *Run workflow* button (`workflow_dispatch`)
   to bump on demand from any branch.

## Rules

* **NEVER** put `_vendor` or `_static_vendor` on `addons_path` — only
  `_selected`. Duplicate module names across vendor repos would otherwise load
  nondeterministically.
* **NEVER** hand-edit `_selected` — edit `selection.txt`, run `make selection`.
* Symlinks must stay **relative** (`../_vendor/...`); absolute paths break in
  Docker/CI checkouts. The generator guarantees this.
* Product-specific knobs (`OWN_MODULES`, `UPGRADE_MODULES`, image name, PG
  tuning `PG_*`) live in the product's Makefile/.env — this repo has **no**
  product defaults.
* **ALWAYS** write a `docs/decisions/` record in the same commit as any
  change to what a product does (see "Decision records" above).

## Day-to-day (run in the product repo root)

| command | effect |
| --- | --- |
| `make up` / `make debug` | dev stack (ports, live mount, reload / debugpy) |
| `make build` | build the prod image |
| `make selection` | regenerate `_selected` from `selection.txt` |
| `make submodules` | bump all `_vendor` submodules to latest upstream (runs `dev-remotes` first) |
| `make dev-remotes` | rewrite SSH submodule URLs to HTTPS in local config (dev machines using `gh`; deploy keeps SSH) |
| `make platform` | bump this platform submodule |
| `make upgrade` / `make init` / `make db*` | module + database ops (see `make help`) |

Deployment specifics (Dokploy, Traefik/nginx routing, backups): see
[DEPLOY.md](DEPLOY.md) — paths there are written from the product-repo-root
perspective.
