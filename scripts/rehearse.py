#!/usr/bin/env python3
"""Local release rehearsal in two tiers: LIGHT (no image build) and FULL.

Run from a product repo checkout (or pass --src). A product wrapper sets the
configuration below and calls this script; see platform/README.md
"Rehearsal before release" for the how-to.

LIGHT  One standing base image (prod core digest + python deps + entrypoint),
       built once per Dockerfile / requirements / core / Hub-frontend change.
       The code under test is exported in the exact prod addons layout
       (`docker build --target addons_tree --output`, i.e. BuildKit applies
       platform/Dockerfile.dockerignore itself) and mounted read-only at
       /opt/extra-addons. Built frontends come from the base image.
FULL   The platform Dockerfile builds a complete image from the same staged
       context, on the prod core digest.

Both tiers then do the same: copy the standing template database (a
neutralized prod-state copy, Postgres TEMPLATE, seconds), boot the prod
entrypoint once (UPGRADE_MODULES=auto -> click-odoo-update), optionally run
module tests and a smoke script, and remove everything they created.

Configuration (environment, normally set by the product wrapper):
  REHEARSE_PG_CONTAINER   Postgres container to use (required)
  REHEARSE_ODOO_IMAGE     prod core image, odoo:19.0@sha256:... (required)
  REHEARSE_IMAGE_REPO     local image name [odoo-product]
  REHEARSE_FIRST_PARTY    submodule paths whose content is classified file by
                          file; a bump of any other submodule means FULL
  REHEARSE_ALIASES        name=submodule-path,... -> --name DIR overrides
  REHEARSE_BASE_REF       ref prod runs [origin/19.0]
  REHEARSE_TEMPLATE_DB    [reh_template]
  REHEARSE_PORT           smoke/--keep port on 127.0.0.1 [8199]
  REHEARSE_ADMIN_PASSWORD admin (id 2) password in the template [rehearse-admin]
  NEUTRALIZE_SQL          product neutralization script [tools/neutralize_db.sql]
"""
import argparse
import ast
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ENV = os.environ
PREFIX = "reh"
TEST_DIRS = ("tests", "test")  # stripped by Dockerfile.dockerignore


def say(msg):
    print(f"\033[1m[rehearse] {msg}\033[0m", flush=True)


def die(msg):
    print(f"[rehearse] ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd, check=True, capture=False, **kw):
    res = subprocess.run(cmd, check=False, text=True,
                         stdout=subprocess.PIPE if capture else None, **kw)
    if check and res.returncode:
        die(f"command failed ({res.returncode}): {' '.join(map(str, cmd))[:300]}")
    return res.stdout if capture else res.returncode


def git(repo, *args, check=True):
    res = subprocess.run(["git", "-C", str(repo), *args], text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and res.returncode:
        die(f"git -C {repo} {' '.join(args)}: {res.stderr.strip()[:300]}")
    return res.stdout if res.returncode == 0 else None


def git_z(repo, *args):
    out = git(repo, *args)
    return [p for p in out.split("\0") if p]


# --------------------------------------------------------------------------
# Repositories: product + submodules (with overrides)
# --------------------------------------------------------------------------
class Repos:
    """The product checkout, its submodules and the --sub overrides."""

    def __init__(self, src, base_ref, overrides):
        self.src = Path(src).resolve()
        self.base_ref = base_ref
        self.overrides = {k: Path(v).resolve() for k, v in overrides.items()}
        self.common = Path(git(self.src, "rev-parse", "--path-format=absolute",
                               "--git-common-dir").strip())
        names = git(self.src, "config", "-f", ".gitmodules", "--get-regexp",
                    r"^submodule\..*\.path$", check=False) or ""
        self.sub_names = {}
        for line in names.splitlines():
            key, path = line.split(" ", 1)
            self.sub_names[path] = key[len("submodule."):-len(".path")]
        for path in self.overrides:
            if path not in self.sub_names:
                die(f"--sub {path}: not a submodule path of {self.src}")

    def pins(self, ref):
        """{path: sha} of the gitlinks at ref (None = index of the checkout)."""
        if ref is None:
            lines = git_z(self.src, "ls-files", "-s", "-z")
        else:
            lines = git_z(self.src, "ls-tree", "-r", "-z", ref)
        pins = {}
        for line in lines:
            meta, path = line.split("\t", 1)
            parts = meta.split()
            if parts[0] == "160000":
                pins[path] = parts[1] if ref is None else parts[2]
        return pins

    def work_dir(self, path):
        """Directory with the submodule's working tree, or None."""
        d = self.overrides.get(path) or self.src / path
        return d if (d / ".git").exists() else None

    def object_repo(self, path, sha):
        """A git dir that has commit sha for this submodule."""
        cands = []
        if self.work_dir(path):
            cands.append(["-C", str(self.work_dir(path))])
        name = self.sub_names.get(path, path)
        for mod in (self.common / "modules" / name, self.common / "modules" / path):
            if mod.is_dir():
                cands.append(["--git-dir", str(mod)])
        for c in cands:
            if subprocess.run(["git", *c, "cat-file", "-e", f"{sha}^{{commit}}"],
                              stderr=subprocess.DEVNULL).returncode == 0:
                return c
        return None


def gitc(c, *args):
    res = subprocess.run(["git", *c, *args], text=True, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
    if res.returncode:
        die(f"git {' '.join(c + list(args))}: {res.stderr.strip()[:300]}")
    return res.stdout


# --------------------------------------------------------------------------
# Tier classification
# --------------------------------------------------------------------------
def worktree_changes(repo, ref):
    """[(status, path)] of the working tree (incl. untracked) against ref."""
    out = git_z(repo, "diff", "--name-status", "--no-renames", "-z",
                "--ignore-submodules=dirty", ref)
    changes = [(out[i][0], out[i + 1]) for i in range(0, len(out), 2)]
    changes += [("A", p) for p in git_z(repo, "ls-files", "-z", "--others",
                                        "--exclude-standard")]
    return changes


def commit_changes(c, old, new):
    out = gitc(c, "diff", "--name-status", "--no-renames", "-z", old, new)
    out = [p for p in out.split("\0") if p]
    return [(out[i][0], out[i + 1]) for i in range(0, len(out), 2)]


def read_old(c, sha, path):
    res = subprocess.run(["git", *c, "show", f"{sha}:{path}"], text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return res.stdout if res.returncode == 0 else ""


def field_defs(source):
    """{(class, field): signature} of Odoo field assignments in a python file."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return None
    defs, models = {}, set()
    for cls in [n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]:
        for stmt in cls.body:
            if not (isinstance(stmt, ast.Assign) and len(stmt.targets) == 1
                    and isinstance(stmt.targets[0], ast.Name)):
                continue
            name, val = stmt.targets[0].id, stmt.value
            if name == "_name" and isinstance(val, ast.Constant):
                models.add(val.value)
            if not (isinstance(val, ast.Call) and isinstance(val.func, ast.Attribute)
                    and isinstance(val.func.value, ast.Name)
                    and val.func.value.id == "fields"):
                continue
            kw = {k.arg: ast.unparse(k.value) for k in val.keywords if k.arg}
            computed = "compute" in kw or "related" in kw
            stored = kw.get("store") == "True" or (not computed and kw.get("store") != "False")
            sig = (val.func.attr, stored) + tuple(
                kw.get(k) for k in ("required", "translate", "index", "related"))
            defs[(cls.name, name)] = sig
    return defs, models


def classify_file(status, path, old_text, new_text, frontend_roots):
    """'full' reason, 'light', or None (not part of the image)."""
    name = path.rsplit("/", 1)[-1]
    if path == "requirements.txt" or name == "requirements.txt":
        return "python requirements changed"
    if path.startswith(("platform/Dockerfile", "platform/docker/")) or path in (
            "platform/scripts/manifest-pydeps.py", "platform/scripts/check-pydeps.py"):
        return "image build or entrypoint changed"
    if not path.startswith("src/"):
        return None
    if path.startswith("src/third_party_addons/_selected/"):
        return "addon selection changed (_selected)"
    if "/migrations/" in path or "/upgrades/" in path:
        return "migration script"
    # Never in the image (Dockerfile.dockerignore strips them), so never a
    # build input. Approximate on purpose: this only picks the tier.
    if name.endswith(".md") or name in (".gitignore", ".gitmodules") or any(
            f"/{d}/" in path for d in ("docs", "doc", ".github") + TEST_DIRS):
        return "light"
    for root, addon_dirs in frontend_roots.items():
        if path.startswith(root + "/"):
            rel = path[len(root) + 1:]
            if name == "build-frontend.sh" or not any(
                    rel.startswith(d + "/") for d in addon_dirs):
                return "frontend build input"
    if name == "__manifest__.py":
        if status == "A":
            return "new module"
        try:
            old = ast.literal_eval(old_text).get("external_dependencies")
            new = ast.literal_eval(new_text).get("external_dependencies")
        except (ValueError, SyntaxError):
            return "manifest not parseable"
        if old != new:
            return "external_dependencies changed"
    if name.endswith(".py") and not any(f"/{d}/" in path for d in TEST_DIRS):
        new = field_defs(new_text) if new_text else ({}, set())
        old = field_defs(old_text) if old_text else ({}, set())
        if new is None or old is None:
            return "python file not parseable"
        (new_f, new_m), (old_f, old_m) = new, old
        if new_m - old_m:
            return f"new model {sorted(new_m - old_m)[0]}"
        for key, sig in new_f.items():
            if sig[1] and old_f.get(key) != sig:
                return f"stored field {key[0]}.{key[1]} added or changed"
    return "light"


def frontend_layout(repo_listing):
    """Addon dirs of a repo listing if it has a build-frontend.sh addon."""
    addon_dirs = sorted({p.rsplit("/", 1)[0] for p in repo_listing
                         if p.endswith("/__manifest__.py")})
    has_hook = any(p.endswith("/build-frontend.sh") for p in repo_listing)
    return addon_dirs if has_hook else None


def classify(repos, first_party):
    """Return (tier, [reasons], n_light_files)."""
    full, light = [], 0
    base, now = repos.pins(repos.base_ref), repos.pins(None)
    product_changes = [(s, p) for s, p in worktree_changes(repos.src, repos.base_ref)
                       if p not in base and p not in now]
    frontend_roots = {}
    items = []  # (status, product-relative path, old text, new text)
    for status, p in product_changes:
        old = read_old(["-C", str(repos.src)], repos.base_ref, p) if status != "A" else ""
        f = repos.src / p
        new = f.read_text(errors="replace") if f.is_file() and not f.is_symlink() else ""
        items.append((status, p, old, new))
    for path in sorted(set(base) | set(now) | set(repos.overrides)):
        old_sha = base.get(path)
        if old_sha is None:
            full.append(f"new submodule {path}")
            continue
        wd = repos.work_dir(path)
        if path not in repos.overrides and now.get(path) == old_sha and (
                wd is None or not git(wd, "status", "--porcelain",
                                      "--untracked-files=normal").strip()):
            continue
        if path == "platform":
            c = repos.object_repo(path, old_sha)
            if not c or not wd:
                full.append("platform changed (cannot inspect)")
                continue
            for s, p in worktree_changes(wd, old_sha):
                r = classify_file(s, f"platform/{p}", "", "", {})
                if r not in (None, "light"):
                    full.append(f"{r}: platform/{p}")
            continue
        if path not in first_party:
            full.append(f"vendor submodule bump: {path} {old_sha[:7]} -> {now.get(path, '?')[:7]}")
            continue
        c = repos.object_repo(path, old_sha)
        if c is None:
            full.append(f"{path}: commit {old_sha[:7]} not available locally")
            continue
        if wd:
            changes = worktree_changes(wd, old_sha)
            listing = git_z(wd, "ls-files", "-z")
        else:
            changes = commit_changes(c, old_sha, now[path])
            listing = [p for p in gitc(c, "ls-tree", "-r", "-z", "--name-only",
                                       now[path]).split("\0") if p]
        layout = frontend_layout(listing)
        if layout is not None:
            frontend_roots[path] = layout
        for s, p in changes:
            old = read_old(c, old_sha, p) if s != "A" else ""
            if wd:
                f = wd / p
                new = f.read_text(errors="replace") if f.is_file() and not f.is_symlink() else ""
            else:
                new = read_old(c, now[path], p) if s != "D" else ""
            items.append((s, f"{path}/{p}", old, new))
    for s, p, old, new in items:
        r = classify_file(s, p, old, new, frontend_roots)
        if r == "light":
            light += 1
        elif r is not None:
            full.append(f"{r}: {p}")
    return ("full" if full else "light"), full, light


# --------------------------------------------------------------------------
# Build context staging
# --------------------------------------------------------------------------
def wanted(path):
    return path == "requirements.txt" or path.startswith("src/")


def stage_worktree(repos, dest):
    """Sync what `git add -A` would commit (product + submodules, overrides
    applied) into dest. Only src/, requirements.txt and platform/ (the paths
    platform/Dockerfile reads)."""
    files = {}  # rel -> absolute source

    def collect(repo, prefix, top):
        tracked = git_z(repo, "ls-files", "-z", "-s")
        links = {line.split("\t", 1)[1] for line in tracked
                 if line.startswith("160000 ")}
        paths = [line.split("\t", 1)[1] for line in tracked]
        paths += git_z(repo, "ls-files", "-z", "--others", "--exclude-standard")
        for p in paths:
            rel = f"{prefix}{p}"
            if p in links or (top and not wanted(rel)):
                continue
            f = Path(repo) / p
            if f.is_symlink() or f.exists():
                files[rel] = f
        return links

    links = collect(repos.src, "", True)
    for path in sorted(links):
        if not (path == "platform" or wanted(path)):
            continue
        wd = repos.work_dir(path)
        if wd is None:
            die(f"submodule {path} is not checked out "
                "(git submodule update --init) -- prod would fail the same way")
        collect(wd, f"{path}/", False)
    dest.mkdir(parents=True, exist_ok=True)
    copied = 0
    for rel, srcf in files.items():
        d = dest / rel
        if srcf.is_symlink():
            target = os.readlink(srcf)
            if d.is_symlink() and os.readlink(d) == target:
                continue
            if d.is_symlink() or d.exists():
                shutil.rmtree(d) if d.is_dir() and not d.is_symlink() else d.unlink()
            d.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(target, d)
            copied += 1
            continue
        st = srcf.stat()
        if d.is_file() and not d.is_symlink():
            dt = d.stat()
            if dt.st_size == st.st_size and dt.st_mtime_ns == st.st_mtime_ns:
                continue
        if d.is_symlink():
            d.unlink()
        elif d.is_dir():
            shutil.rmtree(d)
        d.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(srcf, d)
        copied += 1
    removed = 0
    for root, dirs, fnames in os.walk(dest, topdown=False):
        for n in fnames + [x for x in dirs if (Path(root) / x).is_symlink()]:
            rel = os.path.relpath(Path(root) / n, dest)
            if rel not in files:
                (Path(root) / n).unlink()
                removed += 1
        if root != str(dest) and not os.listdir(root):
            os.rmdir(root)
    return len(files), copied, removed


def stage_ref(repos, ref, dest):
    """Fresh context from a git ref: product + pinned submodules (git archive)."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    def extract(c, sha, sub, paths=()):
        target = dest / sub if sub else dest
        target.mkdir(parents=True, exist_ok=True)
        arch = subprocess.Popen(["git", *c, "archive", "--format=tar", sha, *paths],
                                stdout=subprocess.PIPE)
        subprocess.run(["tar", "-xf", "-", "-C", str(target)], stdin=arch.stdout, check=True)
        if arch.wait():
            die(f"git archive {sha} failed for {sub or 'product'}")

    extract(["-C", str(repos.src)], ref, "", ("src", "requirements.txt"))
    for path, sha in repos.pins(ref).items():
        if not (path == "platform" or wanted(path)):
            continue
        c = repos.object_repo(path, sha)
        if c is None:
            die(f"submodule {path}: commit {sha[:7]} of {ref} not available locally "
                "(git submodule update --init, or fetch it)")
        extract(c, sha, path)


# --------------------------------------------------------------------------
# Base image key (what the base image depends on, from git objects at ref)
# --------------------------------------------------------------------------
def base_key(repos, ref, core, first_party):
    h = hashlib.sha256()
    h.update(core.encode())
    pins = repos.pins(ref)
    for spec in ("requirements.txt", "src/third_party_addons/_static_vendor"):
        h.update((git(repos.src, "rev-parse", f"{ref}:{spec}", check=False) or "-").encode())
    for path, sha in sorted(pins.items()):
        if path == "platform":
            c = repos.object_repo(path, sha) or die("platform commit not available")
            for p in ("Dockerfile", "Dockerfile.dockerignore", "docker",
                      "scripts/manifest-pydeps.py", "scripts/check-pydeps.py"):
                h.update(gitc(c, "rev-parse", f"{sha}:{p}").encode())
        elif path in first_party:
            c = repos.object_repo(path, sha) or die(f"{path} {sha[:7]} not available")
            listing = gitc(c, "ls-tree", "-r", "-z", sha).split("\0")
            names = [e.split("\t", 1)[1] for e in listing if "\t" in e]
            layout = frontend_layout(names)
            for e in listing:
                if "\t" not in e:
                    continue
                meta, p = e.split("\t", 1)
                n = p.rsplit("/", 1)[-1]
                fe = layout is not None and (n == "build-frontend.sh" or not any(
                    p.startswith(d + "/") for d in layout))
                if n == "requirements.txt" or fe:
                    h.update(f"{path}/{p} {meta}\n".encode())
        elif wanted(path):
            h.update(f"{path} {sha}\n".encode())
    return h.hexdigest()[:12]


# --------------------------------------------------------------------------
# Docker / Postgres helpers
# --------------------------------------------------------------------------
class PG:
    def __init__(self, container):
        info = json.loads(run(["docker", "inspect", container], capture=True))[0]
        if not info["State"]["Running"]:
            die(f"Postgres container {container} is not running")
        env = dict(e.split("=", 1) for e in info["Config"]["Env"])
        self.container = container
        self.user = env.get("POSTGRES_USER", "postgres")
        self.password = env.get("POSTGRES_PASSWORD", "")
        self.network = sorted(info["NetworkSettings"]["Networks"])[0]

    def sql(self, sql, db="postgres", capture=True):
        return run(["docker", "exec", "-i", self.container, "psql", "-U", self.user,
                    "-X", "-q", "-At", "-F", "|", "-v", "ON_ERROR_STOP=1", "-d", db],
                   input=sql, capture=capture)

    def exists(self, db):
        return self.sql(f"SELECT 1 FROM pg_database WHERE datname = '{db}'").strip() == "1"

    def drop(self, db):
        self.sql(f'DROP DATABASE IF EXISTS "{db}" WITH (FORCE)')

    def odoo_env(self):
        return ["-e", f"DB_HOST={self.container}", "-e", "DB_PORT=5432",
                "-e", f"DB_USER={self.user}", "-e", f"DB_PASSWORD={self.password}"]


def image_exists(ref):
    return subprocess.run(["docker", "image", "inspect", ref], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def docker_build(ctx, args, log):
    say(f"docker build {' '.join(args)}  (log: {log})")
    t = time.time()
    with open(log, "w") as fh:
        rc = subprocess.run(["docker", "build", "--progress=plain", "-f",
                             str(ctx / "platform" / "Dockerfile"), *args, str(ctx)],
                            stdout=fh, stderr=subprocess.STDOUT).returncode
    if rc:
        subprocess.run(["tail", "-30", str(log)])
        die(f"docker build failed, see {log}")
    say(f"  built in {time.time() - t:.0f}s")


def odoo_run(cfg, pg, image, name, log, env=(), mounts=(), args=(), detach=False, port=None,
             entrypoint=None):
    cmd = ["docker", "run", "--name", name, "--network", pg.network,
           "--label", f"{PREFIX}.run={cfg.run_id}",
           "-v", f"{cfg.volume}:/var/lib/odoo", *pg.odoo_env(),
           "-e", "WORKERS=0", "-e", "MAX_CRON_THREADS=0", "-e", "LOG_LEVEL=info"]
    for m in mounts:
        cmd += ["-v", m]
    for e in env:
        cmd += ["-e", e]
    if detach:
        cmd += ["-d", "-p", f"127.0.0.1:{port}:8069"]
    else:
        cmd += ["--rm"]
    if entrypoint:
        cmd += ["--entrypoint", entrypoint]
    cmd += [image, *args]
    if detach:
        return run(cmd, capture=True).strip()
    with open(log, "w") as fh:
        return subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT).returncode


def log_summary(log):
    text = Path(log).read_text(errors="replace")
    errors = [l for l in text.splitlines() if re.search(r" (ERROR|CRITICAL) ", l)]
    warns = [l for l in text.splitlines() if " WARNING " in l]
    return text, errors, warns


# --------------------------------------------------------------------------
# Neutralization check (same rules as rehearse-upgrade.sh)
# --------------------------------------------------------------------------
MUST_ZERO = {"active crons", "mail servers with real host", "fetchmail servers",
             "mail_mail outgoing/exception", "active online bank providers",
             "EB connections with session", "EB connections with application_id",
             "EB private keys in encrypted_data", "active backup configs",
             "active llm providers", "llm providers with api_key",
             "non-disabled payment providers", "users with password (not id 2)"}


def neutralize(pg, db, sql_file):
    out = run(["docker", "exec", "-i", pg.container, "psql", "-U", pg.user, "-X", "-q",
               "-At", "-F", "|", "-v", "ON_ERROR_STOP=1", "--single-transaction", "-d", db],
              input=Path(sql_file).read_text(), capture=True)
    bad, seen = [], set()
    for line in out.splitlines():
        r = line.split("|")
        if len(r) == 2:
            seen.add(r[0])
            if r[0] in MUST_ZERO and r[1] not in ("0", ""):
                bad.append(f"{r[0]} = {r[1]}")
            if r[0] == "database.is_neutralized" and r[1] != "True":
                bad.append("database.is_neutralized != True")
            if r[0] == "database.uuid" and not r[1].startswith("NEUTRALIZED-"):
                bad.append("database.uuid not neutralized")
        elif len(r) == 3:
            bad.append(f"secret left in {r[0]}.{r[1]} ({r[2]} rows)")
    if MUST_ZERO - seen:
        bad.append(f"VERIFY rows missing: {sorted(MUST_ZERO - seen)}")
    if bad:
        die(f"neutralization NOT verified on {db}:\n  " + "\n  ".join(bad))
    say(f"  neutralization verified on {db}")


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------
def ensure_base(cfg, repos, force=False):
    key = base_key(repos, cfg.base_ref, cfg.core, cfg.first_party)
    tag = f"{cfg.repo}:{PREFIX}-base-{key}"
    if image_exists(tag) and not force:
        say(f"base image {tag} is current")
        return tag
    say(f"building base image {tag} from {cfg.base_ref} on {cfg.core}")
    ctx = cfg.home / "ctx-base"
    stage_ref(repos, cfg.base_ref, ctx)
    sha = git(repos.src, "rev-parse", cfg.base_ref).strip()
    docker_build(ctx, ["--build-arg", f"ODOO_IMAGE={cfg.core}",
                       "--label", f"{PREFIX}.key={key}", "--label", f"{PREFIX}.ref={sha}",
                       "-t", tag], cfg.home / f"build-base-{key}.log")
    shutil.rmtree(ctx)
    return tag


def refresh_template(cfg, repos, pg, base, from_db, from_backup):
    tpl, new = cfg.template, f"{cfg.template}_new"
    sha = git(repos.src, "rev-parse", cfg.base_ref).strip()
    pg.drop(new)
    if from_backup:
        say(f"restore {from_backup} -> {new}")
        with tempfile.TemporaryDirectory() as tmp:
            run(["unzip", "-q", "-o", from_backup, "dump.sql", "-d", tmp])
            pg.sql(f'CREATE DATABASE "{new}" OWNER "{pg.user}"')
            with open(Path(tmp) / "dump.sql") as fh:
                subprocess.run(["docker", "exec", "-i", pg.container, "psql", "-U", pg.user,
                                "-X", "-q", "-d", new], stdin=fh, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
        source = Path(from_backup).name
    else:
        say(f"copy {from_db} -> {new} (pg_dump, the source stays untouched)")
        pg.sql(f'CREATE DATABASE "{new}" OWNER "{pg.user}"')
        run(["docker", "exec", pg.container, "sh", "-c",
             f'pg_dump -U "{pg.user}" "{from_db}" | psql -X -q -U "{pg.user}" -d "{new}" >/dev/null'])
        source = from_db
    say("neutralize before any Odoo process touches it")
    neutralize(pg, new, cfg.neutralize_sql)
    pw = run(["docker", "run", "--rm", "--entrypoint", "python3", base, "-c",
              "import sys; from passlib.context import CryptContext; "
              "print(CryptContext(['pbkdf2_sha512']).hash(sys.argv[1]))", cfg.admin_pw],
             capture=True).strip().splitlines()[-1]
    pg.sql(f"UPDATE res_users SET password = '{pw}' WHERE id = 2", db=new)
    cfg.volume = f"{PREFIX}-template-data"
    run(["docker", "volume", "create", cfg.volume], capture=True)
    log = cfg.home / "template-upgrade.log"
    say(f"odoo neutralize + prod entrypoint upgrade to {cfg.base_ref} ({sha[:7]}), log {log}")
    rc = odoo_run(cfg, pg, base, f"{PREFIX}-template-neutralize", cfg.home / "template-neutralize.log",
                  entrypoint="bash", args=["-c", 'exec odoo neutralize --db_host "$DB_HOST" '
                                           '--db_port "$DB_PORT" --db_user "$DB_USER" '
                                           '--db_password "$DB_PASSWORD" --data-dir /var/lib/odoo '
                                           f'-d "{new}" --addons-path=/usr/lib/python3/dist-packages/odoo/addons,'
                                           '/opt/extra-addons/custom_addons,/opt/extra-addons/third_party_addons/_selected'])
    rc = rc or odoo_run(cfg, pg, base, f"{PREFIX}-template-upgrade", log,
                        env=[f"UPGRADE_DB={new}", "UPGRADE_MODULES=auto", "DB_NAME=False"],
                        args=["--stop-after-init"])
    run(["docker", "volume", "rm", cfg.volume], capture=True)
    if rc:
        die(f"template upgrade failed (exit {rc}), see {log}; {tpl} left as it was")
    say("re-neutralize after the upgrade (new modules may add crons)")
    neutralize(pg, new, cfg.neutralize_sql)
    # No filestore comes with the template: drop asset bundles so each run
    # regenerates them instead of pointing at missing files.
    pg.sql("DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%'", db=new)
    if pg.exists(tpl):
        pg.sql(f'ALTER DATABASE "{tpl}" IS_TEMPLATE false')
        pg.drop(tpl)
    pg.sql(f'ALTER DATABASE "{new}" RENAME TO "{tpl}"')
    pg.sql(f'ALTER DATABASE "{tpl}" IS_TEMPLATE true')
    note = f"{PREFIX}: {cfg.base_ref}={sha} core={cfg.core} from={source} at={time.strftime('%Y-%m-%d %H:%M')}"
    pg.sql(f"COMMENT ON DATABASE \"{tpl}\" IS '{note}'")
    say(f"template {tpl} ready: {note}")


def template_note(pg, tpl):
    return pg.sql(f"SELECT shobj_description(oid, 'pg_database') FROM pg_database "
                  f"WHERE datname = '{tpl}'").strip()


def clean(cfg, pg, current_base):
    names = run(["docker", "ps", "-a", "--format", "{{.Names}}"], capture=True).split()
    for n in names:
        if n.startswith(f"{PREFIX}-"):
            run(["docker", "rm", "-f", n], capture=True)
            say(f"removed container {n}")
    for v in run(["docker", "volume", "ls", "--format", "{{.Name}}"], capture=True).split():
        if v.startswith(f"{PREFIX}-"):
            run(["docker", "volume", "rm", v], capture=True)
            say(f"removed volume {v}")
    dbs = pg.sql(f"SELECT datname FROM pg_database WHERE datname LIKE '{PREFIX}\\_%' "
                 f"AND datname <> '{cfg.template}'").split()
    for db in dbs:
        pg.drop(db)
        say(f"dropped database {db}")
    for img in run(["docker", "images", cfg.repo, "--format", "{{.Repository}}:{{.Tag}}"],
                   capture=True).split():
        tag = img.split(":", 1)[1]
        if tag.startswith(f"{PREFIX}-") and img != current_base:
            run(["docker", "rmi", img], capture=True, check=False)
            say(f"removed image {img}")
    runs = cfg.home / "runs"
    if runs.exists():
        shutil.rmtree(runs)
        say(f"removed {runs}")


def test_dirs(stage_dir, modules):
    """(source dir, path under /opt/extra-addons) of each module's tests."""
    for mod in modules:
        found = None
        for base in ("src/custom_addons", "src/third_party_addons/_selected"):
            p = stage_dir / base / mod
            if p.exists():
                found = p.resolve()
        if not found:
            die(f"module {mod} not found in custom_addons or _selected")
        rel = found.relative_to((stage_dir / "src").resolve())
        for d in TEST_DIRS:
            if (found / d).is_dir():
                yield found / d, rel / d


def wait_http(url, timeout=180):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                if r.status == 200:
                    return True
        except Exception:
            time.sleep(2)
    return False


def main():
    aliases = dict(a.split("=", 1) for a in ENV.get("REHEARSE_ALIASES", "").split(",") if "=" in a)
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tier", choices=("light", "full"), help="override the suggestion")
    ap.add_argument("--modules", default="", help="a,b: run these modules' tests")
    ap.add_argument("--smoke", help="executable run against the server "
                    "(env REH_URL, REH_DB, REH_LOGIN, REH_PASSWORD)")
    ap.add_argument("--keep", action="store_true", help="leave server, DB and tree for manual testing")
    ap.add_argument("--detect", action="store_true", help="only print the tier suggestion")
    ap.add_argument("--refresh-base", action="store_true",
                    help="rebuild the base image and the template database")
    ap.add_argument("--from-db", help="--refresh-base: neutralized database to copy")
    ap.add_argument("--from-backup", help="--refresh-base: Odoo backup zip (dump.sql inside)")
    ap.add_argument("--clean", action="store_true", help=f"remove {PREFIX}-* containers, "
                    "volumes, DBs and superseded base images")
    ap.add_argument("--src", default=".", help="product checkout under test [.]")
    ap.add_argument("--base", default=ENV.get("REHEARSE_BASE_REF", "origin/19.0"),
                    help="ref prod runs; the diff and the template are against it")
    ap.add_argument("--sub", action="append", default=[], metavar="PATH=DIR",
                    help="use DIR as the working tree of submodule PATH")
    for name, path in aliases.items():
        ap.add_argument(f"--{name}", metavar="DIR", help=f"same as --sub {path}=DIR")
    a = ap.parse_args()

    overrides = dict(s.split("=", 1) for s in a.sub)
    for name, path in aliases.items():
        if getattr(a, name.replace("-", "_")):
            overrides[path] = getattr(a, name.replace("-", "_"))

    class Cfg:
        pass
    cfg = Cfg()
    cfg.core = ENV.get("REHEARSE_ODOO_IMAGE", "")
    cfg.repo = ENV.get("REHEARSE_IMAGE_REPO", "odoo-product")
    cfg.first_party = {p for p in ENV.get("REHEARSE_FIRST_PARTY", "").split(",") if p}
    cfg.template = ENV.get("REHEARSE_TEMPLATE_DB", f"{PREFIX}_template")
    cfg.port = int(ENV.get("REHEARSE_PORT", "8199"))
    cfg.admin_pw = ENV.get("REHEARSE_ADMIN_PASSWORD", "rehearse-admin")
    cfg.base_ref = a.base
    repos = Repos(a.src, a.base, overrides)
    cfg.neutralize_sql = Path(ENV.get("NEUTRALIZE_SQL", repos.src / "tools" / "neutralize_db.sql"))
    cfg.home = repos.common.parent / ".local" / "rehearse"
    cfg.home.mkdir(parents=True, exist_ok=True)

    if a.clean or a.refresh_base:
        tier, reasons, n_light = None, [], 0
    else:
        tier, reasons, n_light = classify(repos, cfg.first_party)
    if tier:
        say(f"suggested tier: {tier.upper()}  ({n_light} light file(s) vs {a.base}"
        + (", overrides: " + ", ".join(f"{k}={v}" for k, v in overrides.items()) if overrides else "") + ")")
        for r in reasons[:15]:
            print(f"    FULL because {r}")
        if len(reasons) > 15:
            print(f"    ... and {len(reasons) - 15} more")
    if a.detect:
        return
    if "@sha256:" not in cfg.core:
        die("REHEARSE_ODOO_IMAGE must be the prod core pinned by digest (odoo:19.0@sha256:...)")
    pg = PG(ENV.get("REHEARSE_PG_CONTAINER") or die("REHEARSE_PG_CONTAINER is not set"))

    if a.clean:
        key = base_key(repos, cfg.base_ref, cfg.core, cfg.first_party)
        clean(cfg, pg, f"{cfg.repo}:{PREFIX}-base-{key}")
        return
    if a.refresh_base:
        base = ensure_base(cfg, repos, force=True)
        if a.from_db or a.from_backup or not pg.exists(cfg.template):
            if not (a.from_db or a.from_backup):
                die(f"{cfg.template} does not exist: pass --from-db or --from-backup")
            cfg.run_id = "template"
            refresh_template(cfg, repos, pg, base, a.from_db, a.from_backup)
        return
    if a.tier and a.tier != tier:
        say(f"tier {a.tier.upper()} chosen explicitly")
    tier = a.tier or tier
    if not pg.exists(cfg.template):
        die(f"no template database {cfg.template}: run --refresh-base --from-db <neutralized db>")
    note = template_note(pg, cfg.template)
    sha = git(repos.src, "rev-parse", a.base).strip()
    if sha not in note:
        say(f"WARNING: template is not at {a.base} ({sha[:7]}): {note or 'no note'}; "
            "the boot upgrade will also apply what changed since (run --refresh-base to align)")

    t0 = time.time()
    cfg.run_id = time.strftime("%m%d-%H%M%S")
    run_dir = cfg.home / "runs" / cfg.run_id
    run_dir.mkdir(parents=True)
    db = f"{PREFIX}_{cfg.run_id.replace('-', '_')}"
    cfg.volume = f"{PREFIX}-{cfg.run_id}-data"
    created = {"image": None, "server": None}
    timings = {}
    ok = True
    try:
        t = time.time()
        ctx = cfg.home / "ctx-run"
        n, copied, removed = stage_worktree(repos, ctx)
        say(f"staged {n} files into {ctx} ({copied} copied, {removed} removed)")
        mounts = []
        if tier == "light":
            image = ensure_base(cfg, repos)
            tree = run_dir / "tree"
            run(["docker", "build", "-q", "-f", str(ctx / "platform" / "Dockerfile"),
                 "--target", "addons_tree", "--output", f"type=local,dest={tree}", str(ctx)],
                capture=True)
            # Built frontends: files the base image has and the tree lacks,
            # only inside addons with a build-frontend.sh hook.
            hooks = sorted({h.parent.resolve() for h in (tree / "src").glob("*/*/build-frontend.sh")}
                           | {h.parent.resolve() for h in (tree / "src").glob("*/*/*/build-frontend.sh")})
            if hooks:
                cid = run(["docker", "create", image], capture=True).strip()
                try:
                    for addon in hooks:
                        rel = addon.relative_to((tree / "src").resolve())
                        cp = subprocess.Popen(["docker", "cp", f"{cid}:/opt/extra-addons/{rel}/.", "-"],
                                              stdout=subprocess.PIPE)
                        subprocess.run(["tar", "-xkf", "-", "-C", str(addon)], stdin=cp.stdout,
                                       stderr=subprocess.DEVNULL)
                        cp.wait()
                finally:
                    run(["docker", "rm", cid], capture=True)
            mounts = [f"{tree / 'src'}:/opt/extra-addons:ro"]
            say(f"LIGHT: prod-layout tree exported to {tree}, base {image}")
        else:
            image = f"{cfg.repo}:{PREFIX}-full-{cfg.run_id}"
            docker_build(ctx, ["--build-arg", f"ODOO_IMAGE={cfg.core}", "-t", image],
                         run_dir / "build.log")
            created["image"] = image
        timings["prepare"] = time.time() - t

        t = time.time()
        pg.sql(f'CREATE DATABASE "{db}" TEMPLATE "{cfg.template}" STRATEGY FILE_COPY')
        run(["docker", "volume", "create", cfg.volume], capture=True)
        timings["db copy"] = time.time() - t

        t = time.time()
        log = run_dir / "upgrade.log"
        say(f"boot upgrade (prod entrypoint, UPGRADE_MODULES=auto), log {log}")
        rc = odoo_run(cfg, pg, image, f"{PREFIX}-{cfg.run_id}-upgrade", log, mounts=mounts,
                      env=[f"UPGRADE_DB={db}", "UPGRADE_MODULES=auto", "DB_NAME=False"],
                      args=["--stop-after-init"])
        timings["upgrade"] = time.time() - t
        text, errors, warns = log_summary(log)
        upgraded = re.findall(r"click_odoo_contrib.update: Updating addons[^\n]*?:\s*(.*)", text)
        say(f"  exit {rc}, {len(errors)} ERROR, {len(warns)} WARNING"
            + (f"; upgraded: {upgraded[-1][:300]}" if upgraded else ""))
        for l in errors[:10]:
            print("    " + l[:240])
        ok = rc == 0
        if not ok:
            subprocess.run(["tail", "-25", str(log)])

        if ok and a.modules:
            t = time.time()
            mods = [m.strip() for m in a.modules.split(",") if m.strip()]
            tmounts = list(mounts)
            for srcdir, rel in test_dirs(ctx, mods):
                if tier == "light":
                    shutil.copytree(srcdir, tree / "src" / rel, dirs_exist_ok=True, symlinks=True)
                else:
                    tmounts.append(f"{srcdir}:/opt/extra-addons/{rel}:ro")
            log = run_dir / "tests.log"
            say(f"tests {','.join(mods)}, log {log}")
            rc = odoo_run(cfg, pg, image, f"{PREFIX}-{cfg.run_id}-tests", log, mounts=tmounts,
                          args=["-d", db, "--test-tags", ",".join(f"/{m}" for m in mods),
                                "-u", ",".join(mods), "--stop-after-init"])
            timings["tests"] = time.time() - t
            text, errors, _ = log_summary(log)
            res = re.findall(r"(\d+ failed, \d+ error\(s\) of \d+ tests[^\n]*)", text)
            say(f"  exit {rc}: {res[-1] if res else 'no test summary line'}")
            for l in errors[:15]:
                print("    " + l[:240])
            ok = rc == 0 and not errors

        if ok and (a.smoke or a.keep):
            t = time.time()
            name = f"{PREFIX}-{cfg.run_id}-server"
            created["server"] = odoo_run(cfg, pg, image, name, None, mounts=mounts, detach=True,
                                         port=cfg.port, env=[f"DB_NAME={db}"])
            url = f"http://127.0.0.1:{cfg.port}"
            if not wait_http(f"{url}/web/health"):
                subprocess.run(["docker", "logs", "--tail", "30", name])
                die("server did not come up")
            login = pg.sql("SELECT login FROM res_users WHERE id = 2", db=db).strip()
            if a.smoke:
                say(f"smoke {a.smoke} against {url}")
                rc = subprocess.run([a.smoke], env={**ENV, "REH_URL": url, "REH_DB": db,
                                                    "REH_LOGIN": login,
                                                    "REH_PASSWORD": cfg.admin_pw}).returncode
                timings["smoke"] = time.time() - t
                say(f"  smoke exit {rc}")
                ok = rc == 0
                subprocess.run(["docker", "logs", name], stdout=open(run_dir / "server.log", "w"),
                               stderr=subprocess.STDOUT)
            if a.keep:
                say(f"kept: {url}/web/login?db={db}  login {login} / {cfg.admin_pw}")
    finally:
        if not a.keep:
            t = time.time()
            if created["server"]:
                run(["docker", "rm", "-f", f"{PREFIX}-{cfg.run_id}-server"], capture=True, check=False)
            pg.drop(db)
            run(["docker", "volume", "rm", "-f", cfg.volume], capture=True, check=False)
            if created["image"]:
                run(["docker", "rmi", created["image"]], capture=True, check=False)
            if (run_dir / "tree").exists():
                shutil.rmtree(run_dir / "tree")
            timings["cleanup"] = time.time() - t
        else:
            say(f"left behind on purpose (--keep): DB {db}, volume {cfg.volume}, {run_dir}; "
                "remove with --clean")
    total = time.time() - t0
    say(f"{tier.upper()} {'OK' if ok else 'FAILED'} in {total:.0f}s ("
        + ", ".join(f"{k} {v:.0f}s" for k, v in timings.items()) + f"); logs {run_dir}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
