# 2026-11-10 — Rehearsal in two tiers: LIGHT without an image build, FULL as before

## Context

Every push to a product's deploy branch is a prod release and is rehearsed
first. Until now each rehearsal built a full image (about 3.3 GB per tag) and
copied a database by hand; a form change cost minutes of CPU and left images
behind. The owner of hs-addons asked for a two-minute loop for form changes,
without an image build in GitHub. The full reasoning, measurements and the
rejected alternatives are in hs-addons
`docs/decisions/2026-11-10-tiered-local-rehearsal.md`.

## Decision

`scripts/rehearse.py`, called by a product wrapper (`tools/rehearse.sh`), and
a new stage `addons_tree` in `Dockerfile` (`src/` after
`Dockerfile.dockerignore`; the Node stage now copies from it, the shipped
tree is unchanged). LIGHT exports that stage with `--output type=local` and
mounts it into a standing base image; FULL builds the image. Both copy a
neutralized template database, boot the prod entrypoint, run tests and a
smoke script, and remove what they made. The tier is suggested from the
diff. Bulk output goes to a cache dir outside the editor workspace.

The tool is in the platform because the image rules, the entrypoint and the
tree layout are platform-owned and every product needs the same; product
specifics (core digest, Postgres container, first-party submodules) stay in
the product wrapper. AGENTS.md "Rehearsal before release" makes it binding.

## Consequences

Products need a wrapper and a template database (`--refresh-base
--from-db|--from-backup`). The template has no filestore: asset bundles and
SCSS customizations are dropped from it and regenerate per run.
