# 2026-10-30 — Build selected addon frontends from their pinned sources

## Context

Hustlers Hub shares sources between a desktop application and an Odoo addon. Its frontend needs Node and pnpm, but production should consume the normal development branch rather than a separate branch of compiled assets.

## Decision

Add a separate, digest-pinned Node build stage. For each selected or custom addon, run its optional `build-frontend.sh` from the resolved addon directory. The addon owns its commands and dependency lockfile. Remove `node_modules` after building and copy the resulting source tree into the existing Odoo runtime stage. The runtime keeps the same addon paths and existing dependency and symlink guards.

Only selected addons execute hooks. Products without hooks keep their addon content unchanged. Build failures abort image creation. Node and its tools are not copied into the Odoo runtime.

Reject a product-specific path or addon name in the shared Dockerfile, a second committed frontend branch, and release downloads requiring another authentication mechanism for private repositories.

## Consequences

The product's submodule pin identifies the exact frontend sources and lockfile. Normal submodule updates and rollback apply. Frontend dependencies are downloaded during image creation; no build runs against the live database. Hooks must use locked dependency versions and emit their assets inside their addon directory. Builds of products without frontend hooks still use the Node stage but install no frontend packages.
