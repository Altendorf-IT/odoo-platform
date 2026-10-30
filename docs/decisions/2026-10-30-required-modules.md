# 2026-10-30 — Products declare required modules in Git

## Context

Deploying a selected addon only puts its files on disk. An existing database does not install a new addon through checksum upgrades, and requiring an Apps refresh and manual installation prevents repository-driven rollout.

## Findings

The entrypoint already runs `odoo -i INSTALL_MODULES` before checksum upgrades for existing `UPGRADE_DB` targets. The Dockerfile already copies all of the product's `src` directory. Dokploy consumes one Compose file and rewrites it; product Compose includes and overlays do not reliably apply.

## Decision

Read optional `src/custom_addons/required-modules.txt` from the image. Merge its technical module names into `INSTALL_MODULES`, preserving environment entries and deduplicating additions. Allow blank lines and comments; reject invalid names. Use the existing installation paths for both fresh and existing databases.

Reject copying the platform Compose file into each product or putting product addon names in shared platform defaults.

## Consequences

Products without this file retain existing behavior. Database targets remain controlled by `INIT_DB` and `UPGRADE_DB`; no database is created or selected implicitly. Required modules are installed before serving requests on every configured boot; already installed modules remain installed. Removing a name does not uninstall it.

The automatic-upgrade integration test starts with an existing base-only database, installs a probe from the product file, checks environment merging and duplicate handling, then exercises ordinary upgrades without a product file.
