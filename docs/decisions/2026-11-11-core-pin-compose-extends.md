# 2026-11-11 — The core pin reaches every build through compose `extends`

## Context

7769ce1 (10 Nov) put the Odoo core pin in the product's committed
`odoo-core.env` and loaded it with `--env-file .env --env-file odoo-core.env`.
That works for `make`, but Dokploy runs its own command:

```
env -i PATH=... HOME=... docker compose -p <app> --env-file ./.env \
    -f ./docker-compose.yml up -d --build --remove-orphans
```

(Dokploy `packages/server/src/utils/builders/compose.ts`, `createCommand`.)
The shell environment is empty and the only env file is the `.env` Dokploy
writes from its Environment tab. So the pin did not reach a deploy unless
the owner changed the app's deploy command. The owner asked for a pin in
git that deploys pick up without a change in Dokploy.

## Findings

Tested with `docker compose config` (Compose 5.6 on macOS; 2.22 and 2.29 in
`docker:23.0-cli`, `docker:24.0-cli`), with an empty environment as Dokploy
runs it:

- `COMPOSE_ENV_FILES` in `.env` is not read: the explicit `--env-file` wins.
- A build arg without value (`args: [ODOO_IMAGE]`) is not filled from a
  service `env_file` (also with `required: false`); it is dropped.
- `include:` would carry its own `env_file`, but Dokploy's domain feature
  parses the root compose statically and does not expand `include:`
  (DEPLOY.md "Root compose is a symlink").
- `extends: {file: odoo-core.yml, service: odoo-core}` on service `odoo`
  merges the `build.args` of that file into the build, on all three Compose
  versions. A literal value there is not interpolated, so no env file can
  change it. A missing file is an error (`open .../odoo-core.yml: no such
  file or directory`); `extends` has no optional form.

## Decision

- The pin file is `odoo-core.yml`, a small compose file with service
  `odoo-core` and `build.args.ODOO_IMAGE`. `platform/docker-compose.yml`
  service `odoo` extends it and no longer sets `ODOO_IMAGE` itself.
- Git wins: an `ODOO_IMAGE` in `.env` or in the Dokploy Environment has no
  effect on a pinned product. We rejected "Dockerfile guard fails on
  mismatch" as the deploy mechanism: with the Dokploy command unchanged, the
  build arg would still come from the Environment, so every core bump would
  need a manual Dokploy edit, and a forgotten edit is a failed deploy.
- The file is required in every product. An unpinned product writes
  `ODOO_IMAGE: ${ODOO_IMAGE:-odoo:19.0}` there and keeps the `.env` value;
  `scripts/init-product.sh` creates that. This is the one break with 7769ce1's
  "products without the file build as before": no compose mechanism makes
  the extended file optional. The error is immediate and names the file.
- The `core_pin` guard stays (now parsing the `.yml` line, skipped for a
  non-literal value). Under compose it cannot fail any more; it still stops
  a direct `docker build` or a rehearsal override on another core.
- The Makefile goes back to plain `docker compose`; `rehearse.py` reads the
  `.yml` line.
- `bump-submodules.yml` also checks a pinned `odoo-core.yml` against Docker
  Hub and opens a separate PR `auto/bump-core` (never mixed into the
  submodule PR), with the downtime, no-rollback and FULL-rehearsal warning.
  Fail-soft on registry errors; unpinned products and other registries skip.

## Consequences / follow-ups

- Products must add `odoo-core.yml` in the same commit that moves their
  platform pointer past this change (hs-addons does; sciwie-addons has none
  yet).
- A stale `ODOO_IMAGE` in a Dokploy Environment is harmless but misleading;
  delete it.
- The DEPLOY.md instruction to change the Dokploy deploy command is gone.
