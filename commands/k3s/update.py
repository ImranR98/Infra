#!/usr/bin/env python3
"""Update Helm chart versions and container image tags to the latest available.

Scans all YAML files under the k3s component dir and updates:
  - Direct image references (image: <ref>) → highest semver tag or digest
  - Values-based image refs (repository+tag in valuesContent) → highest semver
  - HelmChart versions → highest available from repo/registry

Algorithm per image ref:
  1. If line tagged # PINNED → skip
  2. List all tags from registry (skopeo, cached)
  3. Filter to semver tags; if current tag has a flavor suffix (-alpine), match it
  4. If candidates exist → pick highest semver
  5. If no semver and current is a floating tag (latest/stable/release) → pin by digest
  6. Otherwise → warn and skip

Flags: --dry-run  --verbose/-v  --filter=PATTERN
"""
import functools
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import yaml

# ── discovery ────────────────────────────────────────────────────────────────

_path = Path(__file__).resolve()
ATLAS_ROOT = Path(os.environ.get("ATLAS_ROOT", ""))
if not str(ATLAS_ROOT):
    for parent in _path.parents:
        if (parent / "lib" / "common.sh").exists():
            ATLAS_ROOT = parent
            break
    if not str(ATLAS_ROOT):
        print("Error: cannot find ATLAS_ROOT.", file=sys.stderr)
        sys.exit(1)

TARGET = os.environ.get("TARGET", "")
if not TARGET:
    print("Error: TARGET must be set.  Run via atlas.sh.", file=sys.stderr)
    sys.exit(1)
COMPONENTS = ATLAS_ROOT / "targets" / TARGET / "k3s"

# ── regex constants ──────────────────────────────────────────────────────────

IMAGE_LINE_RE = re.compile(r"^\s*image:\s*(\S+)", re.MULTILINE)
REPO_LINE_RE  = re.compile(r"^\s*repository:\s*(\S+)", re.MULTILINE)
TAG_LINE_RE   = re.compile(r"^\s*tag:\s*(\S+)")
VERSION_LINE_RE = re.compile(r"^\s*version:\s*(\S+)")
SEMVER_TRIPLE_RE  = re.compile(r"^\d+\.\d+\.\d+$")
FLAVOR_RE = re.compile(
    r"(?:^|-)("
    r"alpine|slim|bookworm|bullseye|openssl|uclibc|"
    r"fpm|apache|distroless|debian|noble|jammy|oracle|"
    r"pgvector|vectorchord|amazoncorretto|python-?"
    r")(?:\b|$)",
    re.I,
)
ARCH_RE   = re.compile(r"-(amd64|arm64v8|aarch64|armv6|armv7|i386|s390x|ppc64le)$")
PRERELEASE_RE = re.compile(r"[-_](beta|rc|alpha|dev)\b", re.I)

# Architecture this machine runs
_HOST_ARCH = os.uname().machine
_EXPECTED_ARCH = ("-amd64",) if _HOST_ARCH in ("x86_64", "amd64") else \
                ("-arm64v8", "-aarch64") if _HOST_ARCH in ("aarch64", "arm64") else ()

VERBOSE = False  # set by _parse_args

# ── CLI ──────────────────────────────────────────────────────────────────────

def _parse_args():
    global VERBOSE
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    verbose = "--verbose" in args or "-v" in args
    VERBOSE = verbose
    filter_pat = ""
    for a in args:
        if a.startswith("--filter="):
            filter_pat = a.split("=", 1)[1]
    return dry_run, filter_pat

# ── registry helpers ────────────────────────────────────────────────────────

def _run(cmd, timeout=10):
    # redact credentials from debug output
    _dbg = list(cmd)
    if "--creds" in _dbg:
        i = _dbg.index("--creds") + 1
        if i < len(_dbg):
            _dbg[i] = "***"
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if r.returncode == 0:
            return r.stdout.strip()
        if VERBOSE:
            print(f"    [DEBUG] {' '.join(_dbg)}: rc={r.returncode}", file=sys.stderr)
    except Exception as e:
        if VERBOSE:
            print(f"    [DEBUG] {' '.join(_dbg)}: {e}", file=sys.stderr)
    return None
    return None

def _http_get(url, timeout=10):
    try:
        req = Request(url, headers={"User-Agent": "curl/8.0"})
        with urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8")
    except Exception as e:
        if VERBOSE:
            print(f"    [DEBUG] HTTP {url}: {e}", file=sys.stderr)
    return None

# GHCR needs auth even for public repos
_GH_TOKEN = os.environ.get("GITHUB_TOKEN", "") or os.environ.get("GH_TOKEN", "")


@functools.lru_cache(maxsize=256)
def _skopeo_tags(image):
    cmd = ["skopeo", "list-tags"]
    if _GH_TOKEN and image.startswith("ghcr.io/"):
        cmd += ["--creds", f"_:{_GH_TOKEN}"]
    cmd += [f"docker://{image}"]

    out = _run(cmd)
    if out:
        try:
            return tuple(json.loads(out).get("Tags", []))
        except Exception:
            pass
    return None

@functools.lru_cache(maxsize=256)
def _skopeo_digest(ref):
    out = _run(["skopeo", "inspect", f"docker://{ref}"])
    if out:
        try:
            return json.loads(out).get("Digest", "")
        except Exception:
            pass
    # Docker Hub fallback
    if ref.startswith("docker.io/") or ("/" not in ref and ":" in ref):
        image = ref
        tag = "latest"
        if ":" in image:
            image, tag = image.rsplit(":", 1)
        image = image.removeprefix("docker.io/")
        try:
            t = _http_get(f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{image}:pull") or "{}"
            token = json.loads(t).get("access_token", "")
            if token:
                req = Request(
                    f"https://registry-1.docker.io/v2/{image}/manifests/{tag}",
                    headers={
                        "Authorization": f"Bearer {token}",
                        "Accept": "application/vnd.docker.distribution.manifest.v2+json",
                        "User-Agent": "curl/8.0",
                    },
                )
                with urlopen(req, timeout=15) as resp:
                    d = resp.headers.get("Docker-Content-Digest", "")
                    if d:
                        return d
        except Exception as e:
            if VERBOSE:
                print(f"    [DEBUG] registry v2 {ref}: {e}", file=sys.stderr)
    return ""

# ── semver / filtering ──────────────────────────────────────────────────────

def _semver_key(tag):
    """Turn a tag like '1.30.0-alpine' into a sortable tuple."""
    t = tag[1:] if tag.startswith("v") else tag
    m = re.match(r"^(\d+)(?:\.(\d+)(?:\.(\d+))?)?(.*)", t)
    if not m:
        return None
    major = int(m.group(1))
    minor = int(m.group(2)) if m.group(2) else -1
    patch = int(m.group(3)) if m.group(3) else -1
    suffix = m.group(4) or ""
    # put stable suffixes before prerelease
    if suffix and not re.match(r"^[-_.]\d", suffix) and not PRERELEASE_RE.search(suffix.lower()):
        suffix = "~" + suffix
    comps = sum(1 for g in (m.group(1), m.group(2), m.group(3)) if g is not None)
    return (major, minor, patch, suffix, comps)

def _flavor_of(tag):
    m = FLAVOR_RE.search(tag)
    return f"-{m.group(1).lower()}" if m else ""

def _best_semver(tags, current_tag):
    """Return the highest suitable semver tag for an image ref.
    Respects flavour suffixes (e.g. -alpine) and host architecture.
    Returns empty string if no semver candidate exists."""
    flavor = _flavor_of(current_tag)

    def _ok(t):
        if not t or PRERELEASE_RE.search(t):
            return False
        if not re.match(r"^v?\d+\.\d+", t):
            return False
        tf = _flavor_of(t)
        if flavor:
            if tf != flavor:
                return False
        elif tf:
            # current tag has no flavor — stick to unflavoured tags
            return False
        return True

    candidates = [t for t in tags if _ok(t)]

    # architecture filtering: prefer tags matching host arch
    if _EXPECTED_ARCH:
        arch_filtered = [
            t for t in candidates
            if not ARCH_RE.search(t) or any(t.endswith(a) for a in _EXPECTED_ARCH)
        ]
        if arch_filtered:
            candidates = arch_filtered

    # never switch from a pure multi-arch tag to an arch-specific variant
    if current_tag and not ARCH_RE.search(current_tag):
        candidates = [t for t in candidates if not ARCH_RE.search(t)]

    # major-version pinning for flavoured tags: stay within same major if possible
    if flavor and current_tag and candidates:
        m = re.match(r"^v?(\d+)", current_tag)
        if m:
            major = int(m.group(1))
            same = [c for c in candidates if re.match(rf"^v?{major}\b", c)]
            if same:
                candidates = same

    if not candidates:
        return ""

    return max(candidates, key=lambda t: _semver_key(t) or (0, 0, 0, "", 0))

# ── scanning ────────────────────────────────────────────────────────────────

def _pinned(fpath, content, keyword):
    """Check whether any line in *content* that contains '# PINNED' also
    contains the given *keyword* (e.g. 'image:' or 'version:')."""
    return any(keyword in line for line in content.splitlines() if "# PINNED" in line)


def _image_refs(components_dir, filter_pat):
    """Scan all YAML files and return (direct_refs, values_refs) where each
    entry is a (filepath, raw_ref) tuple.  *direct_refs* are from ``image:``
    lines outside ``valuesContent`` blocks.  *values_refs* are ``repository:``
    + ``tag:`` pairs found *inside* ``spec.valuesContent`` strings."""
    direct = []
    values = []
    for f in sorted(components_dir.rglob("*.yaml")):
        if filter_pat and filter_pat not in str(f):
            continue
        content = f.read_text()
        fpath = str(f)

        # ── direct image refs (skip lines inside valuesContent blocks) ──
        in_vc = 0
        vc_block_scalar = False  # True when valuesContent uses | or |- block scalar
        for line in content.split("\n"):
            stripped = line.strip()
            indent = len(line) - len(line.lstrip())
            if in_vc and indent <= in_vc and not vc_block_scalar:
                in_vc = 0
            if stripped.startswith("valuesContent:"):
                in_vc = indent
                vc_block_scalar = bool(re.match(r"valuesContent:\s*\|", stripped))
                continue
            m = IMAGE_LINE_RE.match(line)
            if not m:
                continue
            ref = m.group(1).strip("\"'")
            if ref and not ref.startswith("$") and ref != "null":
                if not _pinned(fpath, content, ref.rsplit(":", 1)[0]):
                    direct.append((fpath, ref))

        # ── values-based refs (repository + tag inside valuesContent) ──
        if "repository" not in content:
            continue
        try:
            docs = list(yaml.safe_load_all(content))
        except Exception:
            docs = []
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            vc = (doc.get("spec") or {}).get("valuesContent", "")
            if vc and vc != "null" and "repository" in vc:
                try:
                    inner = yaml.safe_load(vc)
                except Exception:
                    inner = None
                if isinstance(inner, dict):
                    for repo, tag in _find_repo_tag_pairs(inner):
                        if repo and tag and not repo.startswith("$"):
                            ref = f"{repo}:{tag}"
                            if not _pinned(fpath, content, repo):
                                values.append((fpath, ref))
    return direct, values


def _find_repo_tag_pairs(doc):
    """Recursively find {repository, tag} dict pairs, skipping known
    non-image keys (env, resources, securityContext, etc.)."""
    skip = frozenset({
        "env", "envFrom", "resources", "securityContext", "extraArgs",
        "extraEnv", "command", "args", "volumeMounts", "volumes", "ports",
        "livenessProbe", "readinessProbe", "startupProbe", "lifecycle",
        "podSecurityContext", "containerSecurityContext", "affinity",
        "tolerations", "nodeSelector", "serviceAccountName",
        "topologySpreadConstraints",
    })
    if isinstance(doc, dict):
        if "repository" in doc and "tag" in doc:
            r, t = doc["repository"], doc["tag"]
            if r is not None and t is not None:
                r, t = str(r), str(t)
                if r and t and r != "null" and t != "null":
                    yield (r, t)
        for k, v in doc.items():
            if k in skip:
                continue
            if isinstance(v, (dict, list)):
                yield from _find_repo_tag_pairs(v)
    elif isinstance(doc, list):
        for item in doc:
            if isinstance(item, (dict, list)):
                yield from _find_repo_tag_pairs(item)

# ── resolution ──────────────────────────────────────────────────────────────

def _resolve_image(ref):
    """Returns (new_ref, status, detail).  *new_ref* may be *ref* itself
    if nothing changed; status is one of 'updated', 'digest', 'skip', 'error'."""
    # parse
    registry = "docker.io"
    image = ref
    tag = "latest"
    prefix = ""
    # strip existing digest
    if "@sha256:" in ref:
        image = image[:image.index("@sha256:")]

    if "/" in image:
        fi = image.index("/")
        maybe_reg = image[:fi]
        if "." in maybe_reg or ":" in maybe_reg or maybe_reg == "localhost":
            registry = maybe_reg
            image = image[fi + 1:]
            prefix = f"{registry}/"
    if ":" in image:
        image, tag = image.rsplit(":", 1)

    full_img = f"{registry}/{image}"

    tags = _skopeo_tags(full_img)
    if tags is None:
        return ref, "error", f"could not list tags for {full_img}"
    if not tags:
        return ref, "error", f"no tags for {full_img}"

    best = _best_semver(tags, tag)
    if best and best != tag:
        return f"{prefix}{image}:{best}", "updated", f"{tag} → {best}"

    if best == tag:
        return ref, "skip", "already latest"

    # no semver tags — pin floating tag by digest
    if tag in ("latest", "stable", "release", ""):
        digest = _skopeo_digest(f"{full_img}:{tag or 'latest'}")
        if digest:
            new_r = f"{prefix}{image}:{tag or 'latest'}@{digest}"
            if new_r == ref:
                return ref, "skip", "digest unchanged"
            return new_r, "digest", f"pinned {tag or 'latest'} by digest"
        return ref, "error", f"could not get digest for {full_img}:{tag or 'latest'}"

    return ref, "skip", "no semver tags, not a floating tag"

# ── helm charts ─────────────────────────────────────────────────────────────

def _resolve_helm_chart(f, content):
    fpath = str(f)
    if _pinned(fpath, content, "version:"):
        return fpath, "pinned", "", "", ""

    docs = list(yaml.safe_load_all(content))
    hc = None
    for d in docs:
        if isinstance(d, dict) and d.get("kind") == "HelmChart":
            hc = d
            break
    if hc is None:
        return fpath, "skip", "", "", ""

    spec = hc.get("spec", {}) or {}
    chart = spec.get("chart", "") or ""
    repo = spec.get("repo", "") or ""
    current = str(spec.get("version", "") or "").strip('"').lstrip("v")

    version = ""
    if chart.startswith("oci://"):
        tags = _skopeo_tags(chart[6:])  # strip oci://
        version = _highest_semver_str(tags or [])
    elif chart and repo:
        r = _http_get(f"{repo}/index.yaml")
        if r:
            try:
                idx = yaml.safe_load(r)
                entries = (idx.get("entries", {}) or {}).get(chart, [])
                vers = [e["version"] for e in entries if e.get("version") and SEMVER_TRIPLE_RE.match(e["version"].lstrip("v"))]
                version = _highest_semver_str(vers)
            except Exception:
                pass

    label = f"oci://{chart[6:]}" if chart.startswith("oci://") else f"{repo}/{chart}"

    if not version:
        return fpath, "error", label, "", current
    if version == current:
        return fpath, "current", label, version, current
    return fpath, "update", label, version, current


def _highest_semver_str(strings):
    semver = [s.lstrip("v") for s in strings if SEMVER_TRIPLE_RE.match(s.lstrip("v"))]
    if semver:
        return max(semver, key=lambda v: tuple(map(int, v.split("."))))
    return ""

# ── file mutation ───────────────────────────────────────────────────────────

def _apply_direct(content, old_ref, new_ref):
    old = old_ref.split("@sha256:")[0] if "@sha256:" in old_ref else old_ref
    pat = re.compile(rf'^(\s*image:\s*["\']?){re.escape(old)}(?:@sha256:\S+)?(["\']?)', re.MULTILINE)
    return pat.sub(rf"\g<1>{new_ref}\g<2>", content)


def _apply_values(content, repo, new_tag):
    pat = re.compile(
        rf"^(\s*repository:\s*{re.escape(repo)}\s*(?:#.*)?\n"
        rf"(?:[^\n]*\n){{0,5}}?"
        rf"\s*tag:\s*)\S+",
        re.MULTILINE,
    )
    return pat.sub(rf"\g<1>{new_tag}", content, count=1)


def _apply_helm_version(content, old_ver, new_ver):
    pat = re.compile(rf"^(\s*version:\s*v?){re.escape(old_ver)}", re.MULTILINE)
    return pat.sub(rf"\g<1>{new_ver}", content, count=1)


# ── main ────────────────────────────────────────────────────────────────────

def main():
    dry_run, filter_pat = _parse_args()

    print("Update Versions")
    if dry_run:
        print("=== DRY RUN ===")

    # ── Helm charts ─────────────────────────────────────────────────────
    print("\n=== Helm Charts ===")
    helm_files = []
    for f in sorted(COMPONENTS.rglob("*.yaml")):
        if filter_pat and filter_pat not in str(f):
            continue
        c = f.read_text()
        if "kind: HelmChart" in c:
            helm_files.append((f, c))

    chart_count = 0
    for f, content in helm_files:
        path, status, label, version, current = _resolve_helm_chart(f, content)
        if status == "pinned":
            print(f"  {path}: PINNED, skipping")
        elif status == "skip":
            continue
        elif status == "current":
            print(f"  {path}: {label}")
            print(f"    Already at {version}")
        elif status == "update":
            print(f"  {path}: {label}")
            if dry_run:
                print(f"    Would update: {current or 'none'} → {version}")
            else:
                new_content = _apply_helm_version(content, current, version)
                f.write_text(new_content)
                print(f"    Updated: {current or 'none'} → {version}")
            chart_count += 1
        elif status == "error":
            print(f"  {path}: {label or '(unknown)'}")
            print(f"    WARNING: could not query version")
    print(f"  {chart_count} chart(s) updated.")

    # ── Container images ────────────────────────────────────────────────
    print("\n=== Container Images ===")
    direct, values_refs = _image_refs(COMPONENTS, filter_pat)

    # deduplicate
    unique = {}
    for fpath, ref in direct:
        unique.setdefault(ref, []).append(("direct", fpath))
    for fpath, ref in values_refs:
        unique.setdefault(ref, []).append(("values", fpath))

    image_count = 0
    warnings = {"error": [], "digest": []}
    file_cache = {}  # fpath → latest content (so multi-update files don't clobber)

    for ref, entries in sorted(unique.items()):
        new_ref, status, detail = _resolve_image(ref)
        if status in ("skip",):
            continue
        if status == "error":
            warnings["error"].append(f"{ref}: {detail}")
            continue
        if status == "digest":
            warnings["digest"].append(f"{ref}: {detail}")
            # still apply (digest pinning is an update)
        if not dry_run:
            for ftype, fpath in entries:
                content = file_cache.get(fpath)
                if content is None:
                    content = Path(fpath).read_text()
                if ftype == "values":
                    new_tag = new_ref.rsplit(":", 1)[-1]
                    new_tag = new_tag.split("@sha256:")[0] if "@sha256:" in new_tag else new_tag
                    repo = ref.rsplit(":", 1)[0]
                    content = _apply_values(content, repo, new_tag)
                else:
                    content = _apply_direct(content, ref, new_ref)
                file_cache[fpath] = content
        for ftype, fpath in entries:
            print(f"  {fpath}: {ref} → {new_ref}")
            image_count += 1

    # flush any remaining writes
    if not dry_run:
        for fpath, content in file_cache.items():
            Path(fpath).write_text(content)

    print(f"  {image_count} image(s) updated.")

    if warnings["digest"]:
        print("\n=== Pinned by digest (no semver tags available) ===")
        for w in warnings["digest"]:
            print(f"  {w}")
    if warnings["error"]:
        print("\n=== Could not resolve ===")
        for w in warnings["error"]:
            print(f"  {w}")

    msg = "Nothing to update." if dry_run and image_count == 0 else "Done."
    print(f"\n{msg} Review changes with 'git diff' and run './atlas.sh <target> validate'.")


if __name__ == "__main__":
    main()
