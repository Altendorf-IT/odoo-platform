# syntax=docker/dockerfile:1
#
# Authoritative deploy image for an Odoo 19 product repo that consumes this
# platform as a submodule at ./platform. Build context = PRODUCT repo root
# (see platform/docker-compose.yml).
# Base = official Odoo 19 image (clean upstream == our checkout). Pin it for
# reproducibility via ODOO_IMAGE (tag or, better, a sha256 digest) in .env.
#
ARG ODOO_IMAGE=odoo:19.0
FROM ${ODOO_IMAGE}

USER root

# Canonical's archive can be congested or blackholed from some hosting
# providers (Jul 2026: from netcup, archive.ubuntu.com port 80 was dead and
# HTTPS crawled at ~0.3MB/s while German mirrors ran 10-20MB/s). Set
# APT_MIRROR (e.g. https://mirror.23m.com/ubuntu or http://ftp.fau.de/ubuntu)
# to rewrite the archive+security URIs; empty keeps Canonical upstream.
ARG APT_MIRROR=

# Build deps for python wheels that some vendor modules need (cryptography,
# paramiko, PyMuPDF, numpy, ...). gettext-base gives us `envsubst` at runtime.
# NOTE: don't add libpq-dev — the odoo image already ships libpq5 from the PGDG
# repo (newer than Ubuntu's), and libpq-dev would force a conflicting downgrade.
RUN set -eux; \
    if [ -n "$APT_MIRROR" ]; then \
        sed -i -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu#$APT_MIRROR#g" \
            /etc/apt/sources.list.d/ubuntu.sources; \
    fi; \
    apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gettext-base \
    && rm -rf /var/lib/apt/lists/*

# The odoo image's system Python is PEP 668 "externally managed" -> allow pip
# to install into it (this image IS our environment).
ENV PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_ROOT_USER_ACTION=ignore \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install python requirements.
#   - every third_party_addons/{_vendor,_static_vendor}/*/requirements.txt
#   - manifest external_dependencies for modules NOT covered by any
#     requirements.txt (Cybrosys etc. ship none — see manifest-pydeps.py)
#   - the product-root requirements.txt (own / custom extras) — installed
#     LAST so product pins win
# Set INSTALL_VENDOR_REQS=0 to skip vendor reqs for a slim, fast build.
ARG INSTALL_VENDOR_REQS=1

# --- CACHE & PATH OPTIMIZATION: TARGETED BIND MOUNTS ---
# Bind ONLY the dependency sources (not the whole context) so editing our own
# modules can't bust this layer. The pip install only re-runs when the root
# requirements.txt or a vendor module changes.
RUN --mount=type=bind,source=requirements.txt,target=/tmp/src/requirements.txt \
    --mount=type=bind,source=src/third_party_addons/_vendor,target=/tmp/src/third_party_addons/_vendor \
    --mount=type=bind,source=src/third_party_addons/_static_vendor,target=/tmp/src/third_party_addons/_static_vendor \
    --mount=type=bind,source=platform/scripts/manifest-pydeps.py,target=/tmp/src/manifest-pydeps.py \
    --mount=type=cache,target=/root/.cache/pip \
    set -eux; \
    # Debian-packaged dists have no RECORD file, so pip cannot UNINSTALL them:
    # the moment a vendor requirement wants a newer version, the whole install
    # dies with "Cannot uninstall X, RECORD file not found". Installing them
    # first with --ignore-installed puts a pip-managed copy in /usr/local
    # (which precedes dist-packages on sys.path) that pip may replace later.
    # typing-extensions/pyOpenSSL: the GEN_EMAIL crash. idna: pulled >=3.18 by
    # httpx2 via mcp.
    pip install --break-system-packages --ignore-installed \
        typing-extensions pyOpenSSL idna; \
    # Only an explicit 0/false switches the dependency install off. A value
    # that arrives with its .env comment attached ("1  # install every ...")
    # used to compare unequal to "1" and silently skipped EVERY python dep,
    # producing an image that builds green and crashes at registry load with a
    # bare ModuleNotFoundError. Fail loud or work: never silently skip.
    case "${INSTALL_VENDOR_REQS}" in \
        0|0[!0-9]*|false|False|FALSE|no|off) vendor_reqs=0 ;; \
        *) vendor_reqs=1 ;; \
    esac; \
    echo "[build] INSTALL_VENDOR_REQS='${INSTALL_VENDOR_REQS}' -> vendor requirements $([ "$vendor_reqs" = 1 ] && echo ON || echo OFF)"; \
    if [ "$vendor_reqs" = "1" ] && [ -d /tmp/src/third_party_addons ]; then \
        # Not `find -exec`: that swallows a failing pip (find's own exit
        # status is what `set -e` sees), so a dep could quietly not install.
        find /tmp/src/third_party_addons/_vendor \
             /tmp/src/third_party_addons/_static_vendor \
             -maxdepth 2 -name requirements.txt > /tmp/vendor-reqs.list; \
        count=0; \
        while read -r req; do \
            echo "[build] pip install -r $req"; \
            # Retry once ignoring installed dists: the same Debian RECORD
            # problem can surface for any package the base image ships, and
            # naming them one by one above is whack-a-mole. --ignore-installed
            # skips the uninstall step entirely (costs a few duplicate
            # packages, only on the file that actually needed it).
            pip install --break-system-packages -r "$req" || { \
                echo "[build] retrying $req with --ignore-installed"; \
                pip install --break-system-packages --ignore-installed -r "$req"; \
            }; \
            count=$((count + 1)); \
        done < /tmp/vendor-reqs.list; \
        echo "[build] $count vendor requirements file(s) installed"; \
        # Fallback: manifest external_dependencies for modules with no
        # requirements.txt anywhere between them and their vendor root.
        # Odoo 19 checks these names against installed dist metadata, so
        # pip-installing them verbatim is exactly what the check expects.
        python3 /tmp/src/manifest-pydeps.py \
             /tmp/src/third_party_addons/_vendor \
             /tmp/src/third_party_addons/_static_vendor \
             > /tmp/manifest-reqs.txt; \
        if [ -s /tmp/manifest-reqs.txt ]; then \
            pip install --break-system-packages -r /tmp/manifest-reqs.txt; \
        fi; \
    fi; \
    if [ -f /tmp/src/requirements.txt ]; then \
        pip install --break-system-packages -r /tmp/src/requirements.txt; \
    fi

# OpenUpgrade (major-version migration, see OPENUPGRADE in entrypoint.sh).
# OPENUPGRADE=1 bakes in openupgradelib and the OpenUpgrade framework +
# migration scripts at /opt/openupgrade; they stay inert until the container
# runs with env OPENUPGRADE=1. openupgradelib comes from git master: the PyPI
# release (3.13.x) dies on import under Odoo 19 ("module 'odoo' has no
# attribute 'fields'", OCA/openupgradelib#448). Master imports fine once Odoo
# itself is loaded (as it is inside a migration run), hence the odoo imports in
# the check. Tarballs instead of git clones: the image has curl but no git
# (so setuptools-scm needs a pretend version). The branch moves, so rebuild
# with --no-cache before a real migration to pick up the latest scripts.
ARG OPENUPGRADE=1
ARG OPENUPGRADE_BRANCH=19.0
RUN set -eux; \
    if [ "$OPENUPGRADE" = "1" ]; then \
        SETUPTOOLS_SCM_PRETEND_VERSION=0.0.0+master pip install --break-system-packages \
            https://github.com/OCA/openupgradelib/archive/refs/heads/master.tar.gz; \
        (cd /tmp && python3 -c "import odoo.cli, odoo.api, odoo.fields, odoo.models; \
            from openupgradelib import openupgrade"); \
        mkdir -p /opt/openupgrade; \
        curl -fsSL "https://github.com/OCA/OpenUpgrade/archive/refs/heads/${OPENUPGRADE_BRANCH}.tar.gz" \
            | tar -xz -C /opt/openupgrade --strip-components=1 \
                "OpenUpgrade-${OPENUPGRADE_BRANCH}/openupgrade_framework" \
                "OpenUpgrade-${OPENUPGRADE_BRANCH}/openupgrade_scripts"; \
        test -f /opt/openupgrade/openupgrade_framework/__manifest__.py; \
        test -d /opt/openupgrade/openupgrade_scripts/scripts; \
    fi

# click-odoo-update is what UPGRADE_MODULES=auto runs (see docker/entrypoint.sh).
# Odoo 19 needs >=1.24. Its own layer, so it never re-runs the installs above.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --break-system-packages "click-odoo-contrib>=1.24"

# Now copy the src tree for runtime.
# Modifying your code will only hit this layer and below!
#
# NOTE: addons live at /opt/extra-addons, NOT the odoo image's /opt/extra-addons.
# The base image declares `VOLUME /opt/extra-addons`, so anything baked there is
# copied into an ANONYMOUS volume once and then shadowed by that stale volume on
# every redeploy — code changes never reach runtime. /opt/extra-addons is a plain
# image path, so the built code is always what runs. Keep addons off any VOLUME
# path (ADDONS_PATH in the entrypoint points here too).
COPY src /opt/extra-addons

# Guard: fail the build LOUDLY if git submodules weren't checked out (or the
# build context dropped them, e.g. `git archive`). Every _selected entry is a
# relative symlink into _vendor/_static_vendor; a _vendor-backed link dangles
# when its submodule is uninitialized. Verifying each resolves to a real
# __manifest__.py validates the whole chain (submodule content + relative
# symlink) in the actual image — generically, with no product-specific module
# list to maintain (an empty/absent _selected is fine: nothing to check).
RUN set -eu; \
    sel=/opt/extra-addons/third_party_addons/_selected; \
    miss=0; \
    if [ -d "$sel" ]; then \
        for link in "$sel"/*; do \
            [ -e "$link" ] || [ -L "$link" ] || continue; \
            name=$(basename "$link"); \
            if [ ! -f "$link/__manifest__.py" ]; then \
                echo "ERROR: vendored module '$name' is missing (_selected/$name/__manifest__.py did not resolve)." >&2; \
                miss=1; \
            fi; \
        done; \
    fi; \
    if [ "$miss" != 0 ]; then \
        echo "       git submodules are not checked out in the build context." >&2; \
        echo "       Fix: 'git submodule update --init --recursive' before build" >&2; \
        echo "       (in Dokploy/CI, enable submodules; note 'git archive' drops them)." >&2; \
        exit 1; \
    fi; \
    echo "[build] _selected symlinks all resolve — submodules present"

# Guard: every module that can be loaded must have its python deps installed.
# Odoo only checks external_dependencies when a module is INSTALLED; a module
# already installed in a database is imported at registry load, so a missing
# dep is not a failed install, it is a server that will not boot. Catch it here
# instead of at 3am in production.
COPY platform/scripts/check-pydeps.py /tmp/check-pydeps.py
RUN python3 /tmp/check-pydeps.py \
        /opt/extra-addons/custom_addons \
        /opt/extra-addons/third_party_addons/_selected \
    && rm -f /tmp/check-pydeps.py

COPY platform/docker/odoo.conf.template /etc/odoo/odoo.conf.template
COPY platform/docker/entrypoint.sh /usr/local/bin/odoo-entrypoint.sh
COPY platform/docker/healthcheck.py /usr/local/bin/odoo-healthcheck.py
RUN chmod +x /usr/local/bin/odoo-entrypoint.sh /usr/local/bin/odoo-healthcheck.py \
    && chown -R odoo:odoo /opt/extra-addons /etc/odoo

USER odoo

ENTRYPOINT ["/usr/local/bin/odoo-entrypoint.sh"]
CMD []
