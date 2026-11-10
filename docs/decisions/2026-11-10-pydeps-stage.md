# 2026-11-10 — The pip layer is keyed on dependency lists, not on vendor code

## Context

The owner wants a form change rehearsed in about two minutes, without a
full image build for every feature. Timings of `platform/Dockerfile` on the
hs-addons product (Docker Desktop, 8 CPUs, prod core
`odoo:19.0@sha256:0765626…b41b`, pip and pnpm cache mounts warm):

| Build | Wall clock | Biggest steps |
| :-- | --: | :-- |
| No layer cache (`--no-cache`) | 158 s | pip layer 125 s (odoo_llm alone ~105 s: unpinned `llama_index`, `mcp`, `openai`, ... resolved each time), Node frontend stage 67 s (pnpm store was empty), apt 20 s, OpenUpgrade tarballs 7 s |
| Warm, one line changed in an organize_urself view | 46 s | pip layer 33 s, frontend stage 11 s, OpenUpgrade 7 s |

The pip layer bind-mounted the whole `_vendor` and `_static_vendor` trees.
Every byte that changed in any vendored module (organize_urself, the Hub, a
manifest version bump) changed the layer's inputs, so every such build ran all
pip installs again.

## Decision

A new stage `pydeps` (on the same core image, for its `python3`) copies the
vendor trees, collects the `requirements.txt` files the install reads (same
`find -maxdepth 2`, now sorted) and the output of `manifest-pydeps.py`. The
pip layer bind-mounts only that result. BuildKit keys a `from=` bind mount by
its content, so the layer is reused while the dependency lists stay the same.

Measured on the same machine: first build 41 s (pip cache warm), then the
same one-line organize_urself change 15 s instead of 46 s; the pip layer and
the OpenUpgrade layer after it come from cache. `pip freeze` of an image built
with the old and the new Dockerfile is identical (226 packages), and so is
the `/opt/extra-addons` tree (md5 of every file and symlink target).

Rejected for now (reported, not done): a lock file for the unpinned odoo_llm
requirements (cold builds, vendor decision), moving OpenUpgrade above pip
(changes the resolution order), and keying the Node stage on frontend inputs
only (needs knowledge of each hook's output paths).

## Consequences

The vendor `requirements.txt` files install in sorted path order. Before, the
order was whatever the build file system listed. A vendor bump that changes
no dependency no longer costs the pip install; one that does still runs it in
full. Products need no change.
