#!/usr/bin/env python3
"""Pin Helm chart versions and container image tags to specific versions.

This script scans all YAML files under components/ and pins floating container
image references (e.g. "nginx:latest") to specific semver tags (e.g. "nginx:1.30.0-alpine").
It also updates Helm chart versions in helmchart.yaml files.

== How it works ==

1. HELM CHARTS (update_helm_charts):
   - Scans all YAML files under components/ for `kind: HelmChart` CRDs
   - For OCI charts (oci://), queries the registry via skopeo for available tags
   - For HTTP charts, fetches the Helm index.yaml and extracts versions
   - Skips files with "# PINNED" comment on the version line
   - Updates spec.version if a newer semver version exists

2. CONTAINER IMAGES (find_image_refs + resolve_image):
   - Scans YAML files for two kinds of image references:
     a) Direct: lines matching "image: <ref>" in Deployments, Jobs, etc.
     b) Values: repository+tag pairs inside spec.valuesContent blocks
   - Skips images that use variable substitution ($VAR), are marked
     "# PINNED", or are "null"
   - Images pinned by digest (@sha256:...) are NOT skipped — the digest
     is stripped and the tag is resolved normally (e.g. :latest@sha256:old
     is treated as just :latest)


3. IMAGE RESOLUTION (resolve_image):
   The core resolution logic for each image reference:

   a) FLAVORED TAGS (e.g. "1.30.0-alpine", "2.0.22-openssl"):
      These cannot be matched against floating tags because "latest" points
      to the unflavored variant. Instead, find the highest stable tag with
      the same flavor suffix.

   b) FLOATING TAG RESOLUTION (e.g. "nginx:latest" → "nginx:1.30.0"):
      - Fetch the digest of the floating tag (latest, stable, or release)
      - Fetch digests for the top N semver tags (sorted descending)
      - Find which semver tag has the same digest as the floating tag
      - This guarantees we pin to the exact version the float points to

   c) FALLBACK:
      If no floating tag digest match is found, use the highest stable
      semver tag as a best-effort fallback.

   d) SHORT-CIRCUIT:
      If the current tag is already the highest stable semver, skip
      expensive digest comparisons entirely.

4. WRITING UPDATES:
   - Direct refs: regex-replaces "image: <old>" with "image: <new>"
   - Values refs: regex-replaces the "tag:" line after matching "repository:"
   - Preserves YAML quoting (single/double quotes around values)
   - Tracks file content in memory so multiple updates to the same
     file don't overwrite each other

== Performance ==

- Network calls (skopeo, HTTP) are cached via @lru_cache
- Image resolution runs in parallel via ThreadPoolExecutor
- A shared digest pool is reused across all resolve_image calls
- Pinned images are filtered out before resolution (no wasted network calls)
- Files without valuesContent skip YAML parsing entirely

== CLI Flags ==

  --dry-run             Show what would change without modifying files
  --verbose / -v        Log subprocess errors and HTTP failures to stderr
  --filter=PATTERN      Only process component paths matching PATTERN
  --resolve-limit=N     Number of top semver tags to compare against
                        floating tag digests (default: 8)
"""
import functools
import json
import os
import re
import subprocess
import sys
import time
from collections import defaultdict, namedtuple
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import yaml

VARS_ROOT = Path(os.environ.get("VARS_ROOT", Path(__file__).resolve().parent.parent))
TARGET = os.environ.get("TARGET", "")
COMPONENTS = VARS_ROOT / "k3s" / TARGET if TARGET else VARS_ROOT / "k3s" / "sol"
PARALLELISM = os.cpu_count() or 4
INNER_POOL_SIZE = min(4, PARALLELISM)

RefInfo = namedtuple("RefInfo", ["registry", "image", "tag", "prefix"])
ChartResult = namedtuple(
    "ChartResult",
    ["file", "status", "chart", "repo", "version", "current", "content"],
    defaults=["", "", "", "", ""],
)
ResolveResult = namedtuple("ResolveResult", ["resolved", "category", "detail"])

CAT_RESOLVED = "resolved"
CAT_FLAVORED = "flavored"
CAT_MAJOR_AVAIL = "major_available"
CAT_SEMVER_FALLBACK = "semver_fallback"
CAT_ERROR = "error"
CAT_NO_CHANGE = "no_change"
CAT_DIGEST_PIN = "digest_pin"

FLAVOR_RE = re.compile(
    r"^(alpine|slim|bookworm|bullseye|openssl|uclibc)$"
    r"|-(alpine|slim|bookworm|bullseye|openssl|uclibc)$"
)
SEMVER_TAG_RE = re.compile(r"^(\d+)(?:\.(\d+)(?:\.(\d+))?)?(.*)$")
SUFFIX_DIGIT_RE = re.compile(r"^[-_\.]\d")
PRERELEASE_RE = re.compile(r"[-_](beta|rc|alpha|dev)\b")
PURE_SEMVER_RE = re.compile(r"^v?\d+(\.\d+)+$")
PURE_NUMERIC_LINE_RE = re.compile(r"^v?\d+(?:\.\d+)*$")


def _extract_tag(resolved):
    """Extract the tag portion from a resolved image ref, preserving digest pinning."""
    if "@sha256:" in resolved:
        tag_part, digest = resolved.split("@sha256:", 1)
        return tag_part.rsplit(":", 1)[-1] + "@sha256:" + digest
    return resolved.rsplit(":", 1)[-1]

DIRECT_IMAGE_RE = re.compile(r"^\s*image:[^\S\n]*(\S+)", re.MULTILINE)
SEMVER_TRIPLE_RE = re.compile(r"^\d+\.\d+\.\d+$")

_SKIP_KEYS = frozenset({
    "env", "envFrom", "resources", "securityContext", "extraArgs",
    "extraEnv", "command", "args", "volumeMounts", "volumes", "ports",
    "livenessProbe", "readinessProbe", "startupProbe", "lifecycle",
    "podSecurityContext", "containerSecurityContext", "affinity",
    "tolerations", "nodeSelector", "serviceAccountName",
    "topologySpreadConstraints",
})

DRY_RUN = False
VERBOSE = False
FLOAT_TAG_RESOLVE_LIMIT = 8
FILTER = ""
_digest_pool = None
_compiled_re = {}
_pinned_cache = {}

# Detect host CPU architecture to filter arch-specific tags
_HOST_ARCH = os.uname().machine
if _HOST_ARCH in ("x86_64", "amd64"):
    _EXPECTED_ARCH_SUFFIXES = ("-amd64",)
elif _HOST_ARCH in ("aarch64", "arm64"):
    _EXPECTED_ARCH_SUFFIXES = ("-arm64v8", "-aarch64")
else:
    _EXPECTED_ARCH_SUFFIXES = ()
_ARCH_SUFFIX_RE = re.compile(r"-(amd64|arm64v8|aarch64|armv6|armv7|i386|s390x|ppc64le)$")


def _parse_args():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    verbose = "--verbose" in args or "-v" in args
    resolve_limit = 8
    filter_pat = ""
    for a in args:
        if a.startswith("--resolve-limit="):
            try:
                resolve_limit = int(a.split("=", 1)[1])
            except ValueError:
                pass
        elif a.startswith("--filter="):
            filter_pat = a.split("=", 1)[1]
    return dry_run, verbose, resolve_limit, filter_pat


def run(cmd, timeout=3):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if r.returncode == 0:
            return r.stdout.strip()
        if VERBOSE:
            print(f"    [DEBUG] cmd failed (rc={r.returncode}): {' '.join(cmd)}", file=sys.stderr)
            if r.stderr.strip():
                print(f"    [DEBUG] stderr: {r.stderr.strip()[:200]}", file=sys.stderr)
    except subprocess.TimeoutExpired:
        if VERBOSE:
            print(f"    [DEBUG] cmd timed out: {' '.join(cmd)}", file=sys.stderr)
    except FileNotFoundError:
        if VERBOSE:
            print(f"    [DEBUG] command not found: {cmd[0]}", file=sys.stderr)
    return None


def http_get(url, timeout=3):
    try:
        req = Request(url, headers={"User-Agent": "curl/8.0"})
        with urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8")
    except (URLError, HTTPError, OSError) as e:
        if VERBOSE:
            print(f"    [DEBUG] HTTP error for {url}: {e}", file=sys.stderr)
        return None


@functools.lru_cache(maxsize=None)
def skopeo_tags(image):
    """List all tags for a container image via skopeo. Returns tuple or None on error."""
    out = run(["skopeo", "list-tags", f"docker://{image}"])
    if out:
        try:
            return tuple(json.loads(out).get("Tags", []))
        except Exception:
            pass
    return None


@functools.lru_cache(maxsize=None)
def skopeo_digest(ref):
    """Get the digest for a specific image:tag ref. Tries skopeo inspect first,
    then falls back to Docker Registry v2 API for docker.io images."""
    out = run(["skopeo", "inspect", f"docker://{ref}"])
    if out:
        try:
            return json.loads(out).get("Digest", "")
        except Exception:
            pass

    if ref.startswith("docker.io/") or ("/" not in ref and ":" in ref):
        return _registry_v2_digest(ref)
    return ""


def _registry_v2_digest(ref):
    """Fetch a container image digest directly from the Docker Registry v2 API.
    Used as a fallback when skopeo inspect hits Docker Hub rate limits."""
    image = ref
    tag = "latest"
    if ":" in ref:
        image, tag = ref.rsplit(":", 1)
    image = image.removeprefix("docker.io/")

    try:
        token_url = f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{image}:pull"
        token_req = Request(token_url, headers={"User-Agent": "curl/8.0"})
        with urlopen(token_req, timeout=15) as resp:
            token = json.loads(resp.read().decode("utf-8")).get("access_token", "")
        if not token:
            return ""

        manifest_url = f"https://registry-1.docker.io/v2/{image}/manifests/{tag}"
        manifest_req = Request(manifest_url, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.docker.distribution.manifest.list.v2+json,"
                      "application/vnd.docker.distribution.manifest.v2+json,"
                      "application/vnd.oci.image.index.v1+json,"
                      "application/vnd.oci.image.manifest.v1+json",
            "User-Agent": "curl/8.0",
        })
        with urlopen(manifest_req, timeout=15) as resp:
            digest = resp.headers.get("Docker-Content-Digest", "")
            if digest:
                return digest
    except Exception as e:
        if VERBOSE:
            print(f"    [DEBUG] registry v2 fallback failed for {ref}: {e}", file=sys.stderr)
    return ""


def _get_pinned_lines(fpath, content):
    """Return lines containing '# PINNED' for a file, cached by filepath."""
    if fpath not in _pinned_cache:
        _pinned_cache[fpath] = [line for line in content.splitlines() if "# PINNED" in line]
    return _pinned_cache[fpath]


def _is_pinned(plines, keyword):
    """Check if any PINNED line also contains the given keyword."""
    return any(keyword in line for line in plines)


@functools.lru_cache(maxsize=None)
def _semver_key_cached(tag_stripped):
    """Parse a v-stripped tag into a sortable semver tuple. Cached by stripped tag."""
    m = SEMVER_TAG_RE.match(tag_stripped)
    if m:
        major = int(m.group(1))
        minor = int(m.group(2)) if m.group(2) else -1
        patch = int(m.group(3)) if m.group(3) else -1
        suffix = m.group(4) or ""
        if suffix and not SUFFIX_DIGIT_RE.match(suffix) and not PRERELEASE_RE.search(suffix.lower()):
            suffix = "~" + suffix
        comps = sum(1 for p in [m.group(1), m.group(2), m.group(3)] if p is not None)
        return (major, minor, patch, suffix, comps)
    return None


def semver_key(tag):
    """Parse a tag into a sortable semver tuple. Normalizes v-prefix before caching."""
    return _semver_key_cached(tag[1:] if tag.startswith("v") else tag)


def is_prerelease(tag):
    return bool(PRERELEASE_RE.search(tag.lower()))


def is_flavored(tag):
    """Detect known flavor suffixes (e.g. -alpine, -openssl). Returns the suffix or ''."""
    m = FLAVOR_RE.search(tag)
    if m:
        return f"-{m.group(1) or m.group(2)}"
    return ""


def _get_compiled(pattern, flags=0):
    """Cache compiled regex patterns by (pattern, flags) tuple."""
    key = (pattern, flags)
    if key not in _compiled_re:
        _compiled_re[key] = re.compile(pattern, flags)
    return _compiled_re[key]


def _get_suffix_patterns(suffix):
    """Return (exact_re, fuzzy_re) for a flavor suffix. Patterns are cached."""
    sfx = re.escape(suffix)
    return (
        _get_compiled(rf"^v?\d+(?:\.\d+)*{sfx}$"),
        _get_compiled(rf"^v?\d+(?:\.\d+)*[-_].*{sfx}$"),
    )


def highest_stable(tags, suffix="", original_tag=""):
    """Find the highest stable semver tag from a list. Optionally filter by flavor suffix.

    When the current suffix is non-empty (flavored tag), if original_tag has a leading
    major-version number (e.g. "16" in "16-alpine"), only tags within that same
    major version series are returned. Tags from a higher major version are reported
    as a separate return value for user-facing warnings.
    """
    if suffix:
        exact_re, fuzzy_re = _get_suffix_patterns(suffix)
        exact_matches = []
        fuzzy_matches = []
        for t in tags:
            if not t:
                continue
            if exact_re.match(t):
                exact_matches.append(t)
            elif fuzzy_re.match(t) and not is_prerelease(t):
                fuzzy_matches.append(t)
        candidates = exact_matches or fuzzy_matches
    else:
        pure_matches = []
        suffix_matches = []
        for t in tags:
            if not t:
                continue
            if not semver_key(t):
                continue
            if PURE_NUMERIC_LINE_RE.match(t):
                pure_matches.append(t)
            elif not is_prerelease(t):
                suffix_matches.append(t)
        candidates = pure_matches or suffix_matches

    # --- Architecture filtering ---
    if candidates and _EXPECTED_ARCH_SUFFIXES:
        arch_filtered = [t for t in candidates if not _ARCH_SUFFIX_RE.search(t) or
                         any(t.endswith(arch) for arch in _EXPECTED_ARCH_SUFFIXES)]
        if arch_filtered:
            candidates = arch_filtered

    # --- Major-version pinning for flavored tags ---
    # Extract leading major version from ORIGINAL_TAG: "16-alpine" → major=16
    higher_major_available = ""
    leading_major = None
    if suffix and original_tag:
        m = re.match(r"^v?(\d+)", original_tag)
        if m:
            leading_major = int(m.group(1))
    if suffix and candidates and leading_major is not None:
        same_major = []
        other_major = []
        for c in candidates:
            m = re.match(r"^v?(\d+)", c)
            if m:
                mv = int(m.group(1))
                if mv == leading_major:
                    same_major.append(c)
                elif mv > leading_major:
                    other_major.append(c)
        if same_major:
            candidates = same_major
        if other_major:
            highest_other = max(
                (int(re.match(r"^v?(\d+)", c).group(1)) for c in other_major if re.match(r"^v?(\d+)", c)),
                default=0,
            )
            higher_major_available = f"new major version v{highest_other} available"

    if candidates:
        return max(candidates, key=lambda t: semver_key(t) or (0, 0, 0, "", 0)), higher_major_available
    return "", ""


def parse_ref(ref):
    """Parse an image reference into (registry, image, tag, prefix). Handles
    registry-qualified refs (ghcr.io/x/y:tag), port-qualified registries
    (registry:5000/x:tag), and bare refs (nginx:tag).
    Digests (@sha256:...) are stripped so the tag can be resolved normally."""
    tag = "latest"
    image = ref
    # Strip digest suffix: postgres:latest@sha256:abc → postgres:latest
    if "@sha256:" in image:
        image = image[:image.index("@sha256:")]
    # Split registry from the rest of the image path
    registry = "docker.io"
    prefix = ""
    if "/" in image:
        first_slash = image.index("/")
        maybe_reg = image[:first_slash]
        if "." in maybe_reg or ":" in maybe_reg or maybe_reg == "localhost":
            registry = maybe_reg
            image = image[first_slash + 1:]
            prefix = f"{registry}/"
    # Split tag from image
    if ":" in image:
        parts = image.rsplit(":", 1)
        image = parts[0]
        tag = parts[1]
    return RefInfo(registry, image, tag, prefix)


def resolve_image(ref):
    """Resolve a floating/flavored image ref to a pinned semver ref.

    Strategy:
    1. Flavored tags → find highest tag with matching suffix
    2. Already at highest stable → no change (skip digest calls)
    3. Floating tags (latest/stable/release) → match digest to a semver tag
    4. Fallback → use highest stable semver tag
    5. No semver tags → pin floating tag by digest
    """
    ri = parse_ref(ref)

    full_img = f"{ri.registry}/{ri.image}"
    tags = skopeo_tags(full_img)
    if tags is None:
        return ResolveResult(ref, CAT_ERROR, f"error fetching tags for {full_img}")
    if not tags:
        return ResolveResult(ref, CAT_ERROR, f"no tags for {full_img}")

    # Step 1: flavored tags cannot be matched against floating tag digests
    sfx = is_flavored(ri.tag)
    if sfx:
        best, major_warn = highest_stable(tags, sfx, ri.tag)
        if best:
            detail = f"flavored, used highest '{sfx}' tag"
            cat = CAT_FLAVORED
            if major_warn:
                detail += f"; {major_warn}"
                cat = CAT_MAJOR_AVAIL
            return ResolveResult(f"{ri.prefix}{ri.image}:{best}", cat, detail)
        return ResolveResult(ref, CAT_ERROR, f"no '{sfx}' flavored tags for {full_img}")

    # Step 2: short-circuit if current tag is already the highest stable
    best, _ = highest_stable(tags, "")
    if best and best == ri.tag:
        return ResolveResult(ref, CAT_NO_CHANGE, "")

    # Step 3: try to resolve floating tags (latest, stable, release) by digest matching
    available_floats = [ft for ft in ("latest", "stable", "release") if ft in tags]
    float_digests = {}
    if available_floats:
        pool = _digest_pool
        # Fetch all floating tag digests in parallel
        float_futures = {pool.submit(skopeo_digest, f"{full_img}:{ft}"): ft for ft in available_floats}
        for future in as_completed(float_futures):
            ft = float_futures[future]
            d = future.result()
            if d:
                float_digests[ft] = d

        # Sort semver tags descending and fetch digests for top N
        semver_tags = [t for t in tags if PURE_SEMVER_RE.match(t) and t not in available_floats]
        if semver_tags and float_digests:
            semver_tags.sort(key=lambda t: semver_key(t) or (0, 0, 0, "", 0), reverse=True)
            top_semver = semver_tags[:FLOAT_TAG_RESOLVE_LIMIT]

            semver_futures = {pool.submit(skopeo_digest, f"{full_img}:{t}"): t for t in top_semver}
            semver_digests = {}
            for future in as_completed(semver_futures):
                t = semver_futures[future]
                semver_digests[t] = future.result()

            # Check each floating tag against semver digests (prefer latest > stable > release)
            for float_tag in ("latest", "stable", "release"):
                if float_tag not in float_digests:
                    continue
                digest = float_digests[float_tag]
                for t in top_semver:
                    if semver_digests.get(t) == digest:
                        return ResolveResult(f"{ri.prefix}{ri.image}:{t}", CAT_RESOLVED, f"Resolved via '{float_tag}'")

    # Step 4: fallback to highest stable semver
    if best and best != ri.tag:
        return ResolveResult(f"{ri.prefix}{ri.image}:{best}", CAT_SEMVER_FALLBACK, "no floating tag match, used highest semver")

    # Step 5: floating tag with no semver match — pin by digest instead
    if ri.tag in ("latest", "stable", "release"):
        # Use already-fetched digest if available, otherwise fetch it
        digest = float_digests.get(ri.tag)
        if not digest:
            digest = skopeo_digest(f"{full_img}:{ri.tag}")
        if digest:
            return ResolveResult(
                f"{ri.prefix}{ri.image}:{ri.tag}@{digest}",
                CAT_DIGEST_PIN,
                f"pinned '{ri.tag}' by digest (no semver tags available)",
            )

    return ResolveResult(ref, CAT_NO_CHANGE, "")


def highest_semver_string(strings):
    """Find the highest X.Y.Z version from a list of version strings."""
    semver = [s.lstrip("v") for s in strings if SEMVER_TRIPLE_RE.match(s.lstrip("v"))]
    if semver:
        return max(semver, key=lambda v: tuple(map(int, v.split("."))))
    return ""


def _iter_repo_tag_pairs(doc):
    """Recursively find all {repository, tag} dict pairs in a YAML document.
    Skips dict keys in _SKIP_KEYS that can never contain image refs."""
    if isinstance(doc, dict):
        if "repository" in doc and "tag" in doc:
            repo = doc.get("repository")
            tag = doc.get("tag")
            if repo is not None and tag is not None:
                repo_s, tag_s = str(repo), str(tag)
                if repo_s and tag_s and repo_s != "null" and tag_s != "null":
                    yield (repo_s, tag_s)
        for k, v in doc.items():
            if k in _SKIP_KEYS:
                continue
            if isinstance(v, (dict, list)):
                yield from _iter_repo_tag_pairs(v)
    elif isinstance(doc, list):
        for item in doc:
            if isinstance(item, (dict, list)):
                yield from _iter_repo_tag_pairs(item)


def find_image_refs():
    """Scan all YAML files under components/ for unpinned image references.

    Returns (results, file_contents) where:
    - results: list of ("direct"|"values", filepath, ref) tuples
    - file_contents: {filepath: content} dict for later use in updates
    """
    results = []
    file_contents = {}
    for f in sorted(COMPONENTS.rglob("*.yaml")) + sorted(COMPONENTS.rglob("*.yml")):
        if FILTER and FILTER not in str(f):
            continue
        content = f.read_text()
        fpath = str(f)
        file_contents[fpath] = content
        plines = _get_pinned_lines(fpath, content)

        # Direct image refs: "image: <ref>" lines
        # Track valuesContent blocks by indentation to avoid double-matching
        # refs that _iter_repo_tag_pairs will find via parsed YAML.
        lines = content.split("\n")
        in_vc = False
        vc_indent = 0
        for line in lines:
            stripped = line.strip()
            if not stripped:
                continue
            indent = len(line) - len(line.lstrip())

            if in_vc:
                if indent <= vc_indent:
                    in_vc = False
                else:
                    continue

            if stripped.startswith("valuesContent:"):
                in_vc = True
                vc_indent = indent
                continue

            m = DIRECT_IMAGE_RE.match(line)
            if not m:
                continue
            ref = m.group(1).strip('"\'')
            if ref and not ref.startswith("$") and ref != "null":
                if not _is_pinned(plines, ref.rsplit(":", 1)[0]) and not _is_pinned(plines, ref):
                    results.append(("direct", fpath, ref))

        # Values-based refs: repository+tag pairs inside spec.valuesContent
        if "valuesContent" not in content:
            continue
        try:
            docs = list(yaml.safe_load_all(content))
        except Exception:
            docs = []
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            spec = doc.get("spec") or {}
            vc = spec.get("valuesContent", "")
            # Skip YAML parse if no "repository" keyword in the valuesContent string
            if vc and vc != "null" and "repository" in vc:
                try:
                    vc_doc = yaml.safe_load(vc)
                except Exception:
                    vc_doc = None
                if vc_doc and isinstance(vc_doc, dict):
                    for repo, tag in _iter_repo_tag_pairs(vc_doc):
                        if repo and not repo.startswith("$"):
                            ref = f"{repo}:{tag}"
                            if not _is_pinned(plines, repo) and not _is_pinned(plines, ref):
                                results.append(("values", fpath, ref))
    return results, file_contents


def _apply_direct_ref(content, old_ref, new_ref):
    """Replace a direct "image: <old>" with "image: <new>", preserving quotes and whitespace.
    Also consumes any trailing @sha256:... digest on the old ref to avoid double-digest."""
    # Strip any digest from old_ref for matching; the regex will consume it from the file
    old_base = old_ref.split("@sha256:")[0] if "@sha256:" in old_ref else old_ref
    pat = _get_compiled(rf'^(\s*image:\s*["\']?){re.escape(old_base)}(?:@sha256:\S+)?(["\']?)', re.MULTILINE)
    return pat.sub(rf"\g<1>{new_ref}\g<2>", content)


def _apply_values_tag(content, repo, new_tag):
    """Replace the tag: value associated with "repository: <repo>", allowing intervening lines."""
    pat = _get_compiled(
        rf"^(\s*repository:\s*{re.escape(repo)}\s*(?:#.*)?\n"
        rf"(?:[^\n]*\n){{0,5}}?"
        rf"\s*tag:\s*)\S+",
        re.MULTILINE,
    )
    return pat.sub(rf"\g<1>{new_tag}", content, count=1)


def _resolve_helm_chart(f, content):
    """Resolve the latest version for a single HelmChart CRD from potentially multi-doc YAML."""
    fpath = str(f)
    plines = _get_pinned_lines(fpath, content)
    if _is_pinned(plines, "version:"):
        return ChartResult(f, "pinned")

    # Find the HelmChart document in multi-doc YAML
    docs = list(yaml.safe_load_all(content))
    helmchart_doc = None
    for doc in docs:
        if isinstance(doc, dict) and doc.get("kind") == "HelmChart":
            helmchart_doc = doc
            break

    if helmchart_doc is None:
        return ChartResult(f, "skip")

    spec = (helmchart_doc.get("spec") or {}) if isinstance(helmchart_doc, dict) else {}
    chart = spec.get("chart", "") or ""
    repo = spec.get("repo", "") or ""
    version = ""

    if chart.startswith("oci://"):
        ref = chart[6:]
        tags = skopeo_tags(ref)
        if tags:
            version = highest_semver_string(tags)
    elif chart and repo:
        r = http_get(f"{repo}/index.yaml")
        if r:
            try:
                index = yaml.safe_load(r)
                entries = (index.get("entries", {}) or {}).get(chart, [])
                if entries:
                    vers = [
                        e["version"]
                        for e in entries
                        if e.get("version") and SEMVER_TRIPLE_RE.match(e["version"].lstrip("v"))
                    ]
                    if vers:
                        version = highest_semver_string(vers)
            except Exception:
                pass
    else:
        return ChartResult(f, "skip")

    if not version:
        return ChartResult(f, "no_version", chart, repo)

    current = str(spec.get("version", "") or "").strip('"')
    current = current[1:] if current.startswith("v") else current
    version = version[1:] if version.startswith("v") else version
    if current == version:
        return ChartResult(f, "current", chart, repo, version)

    return ChartResult(f, "update", chart, repo, version, current, content)


def _chart_label(chart, repo):
    """Format a human-readable label for a Helm chart source."""
    if chart.startswith("oci://"):
        return f"oci://{chart[6:]}"
    if chart and repo:
        return f"{repo}/{chart}"
    return ""


def update_helm_charts():
    """Find and update all HelmChart CRDs across all YAML files."""
    print("\n=== Helm Charts ===")
    chart_files = []
    for f in sorted(COMPONENTS.rglob("*.yaml")) + sorted(COMPONENTS.rglob("*.yml")):
        if FILTER and FILTER not in str(f):
            continue
        content = f.read_text()
        if "kind: HelmChart" not in content:
            continue
        chart_files.append((f, content))

    count = 0
    with ThreadPoolExecutor(max_workers=PARALLELISM) as pool:
        futures = [pool.submit(_resolve_helm_chart, f, content) for f, content in chart_files]
        for future in futures:
            r = future.result()
            f = r.file
            status = r.status

            if status == "pinned":
                print(f"  {f}: PINNED, skipping")
            elif status == "skip":
                continue
            elif status == "no_version":
                print(f"  {f}: {_chart_label(r.chart, r.repo)}")
                print(f"    WARNING: could not query version")
            elif status == "current":
                print(f"  {f}: {_chart_label(r.chart, r.repo)}")
                print(f"    Already at {r.version}")
            elif status == "update":
                label = _chart_label(r.chart, r.repo)
                print(f"  {f}: {label}")
                if DRY_RUN:
                    print(f"    Would update: {r.current or 'none'} → {r.version}")
                else:
                    if r.current:
                        pat = _get_compiled(rf"^(\s*version:\s*){re.escape(r.current)}", re.MULTILINE)
                        new_content = pat.sub(rf"\g<1>{r.version}", r.content, count=1)
                    else:
                        # Remove existing empty version line, then insert before valuesContent
                        cleaned = re.sub(r"^[ \t]*version:\s*[^\n]*\n?", "", r.content, count=1, flags=re.MULTILINE)
                        new_content = re.sub(
                            r"^(\s*)(valuesContent:.*)", rf"\1version: {r.version}\n\1\2",
                            cleaned, count=1, flags=re.MULTILINE)
                    f.write_text(new_content)
                    print(f"    Updated: {r.current or 'none'} → {r.version}")
                count += 1
    print(f"  {count} chart(s) updated.")


def main():
    global DRY_RUN, VERBOSE, FLOAT_TAG_RESOLVE_LIMIT, FILTER, _digest_pool

    DRY_RUN, VERBOSE, FLOAT_TAG_RESOLVE_LIMIT, FILTER = _parse_args()
    _digest_pool = ThreadPoolExecutor(max_workers=INNER_POOL_SIZE)

    try:
        print("Update Versions")
        if DRY_RUN:
            print("=== DRY RUN ===")

        update_helm_charts()

        print("\n=== Container Images ===")
        refs, file_contents = find_image_refs()

        # Deduplicate refs: same image in multiple files only resolved once
        unique_refs = defaultdict(list)
        for ftype, fpath, ref in refs:
            unique_refs[ref].append((ftype, fpath))

        warnings = {"flavored": [], "major_avail": [], "semver_fallback": [], "problematic": [], "digest_pin": []}
        resolved_map = {}
        total = len(unique_refs)
        done = 0

        def resolve_one(ref):
            t0 = time.monotonic()
            result = resolve_image(ref)
            elapsed = time.monotonic() - t0
            return ref, result, elapsed

        # Resolve all unique image refs in parallel
        with ThreadPoolExecutor(max_workers=PARALLELISM) as pool:
            futures = {pool.submit(resolve_one, ref): ref for ref in unique_refs}
            for future in as_completed(futures):
                ref, result, elapsed = future.result()
                resolved_map[ref] = result.resolved
                done += 1
                if elapsed > 5:
                    print(f"    [TIMING] {ref} took {elapsed:.1f}s")
                if done % 5 == 0 or done == total:
                    print(f"  Resolved {done}/{total} images...")
                if result.category == CAT_FLAVORED:
                    warnings["flavored"].append(f"{ref}: WARNING: {result.detail}")
                elif result.category == CAT_MAJOR_AVAIL:
                    warnings["major_avail"].append(f"{ref}: WARNING: {result.detail}")
                elif result.category == CAT_SEMVER_FALLBACK:
                    warnings["semver_fallback"].append(f"{ref}: WARNING: {result.detail}")
                elif result.category == CAT_ERROR:
                    warnings["problematic"].append(f"{ref}: WARNING: {result.detail}")
                elif result.category == CAT_DIGEST_PIN:
                    warnings["digest_pin"].append(f"{ref}: {result.detail}")

        # Apply updates to files
        image_count = 0

        if DRY_RUN:
            for ref, entries in unique_refs.items():
                resolved = resolved_map.get(ref, ref)
                if resolved == ref:
                    continue
                for ftype, fpath in entries:
                    if ftype == "values":
                        new_tag = _extract_tag(resolved)
                        repo = ref.rsplit(":", 1)[0]
                        print(f"  {fpath}: {ref} → {repo}:{new_tag}")
                    else:
                        print(f"  {fpath}: {ref} → {resolved}")
                    image_count += 1
        else:
            # Track latest content per file so multiple updates to the same
            # file don't overwrite each other
            latest_content = dict(file_contents)
            for ref, entries in unique_refs.items():
                resolved = resolved_map.get(ref, ref)
                if resolved == ref:
                    continue
                for ftype, fpath in entries:
                    content = latest_content[fpath]
                    if ftype == "values":
                        new_tag = _extract_tag(resolved)
                        repo = ref.rsplit(":", 1)[0]
                        new_content = _apply_values_tag(content, repo, new_tag)
                        if new_content != content:
                            Path(fpath).write_text(new_content)
                            latest_content[fpath] = new_content
                            print(f"  {fpath}: {ref} → {repo}:{new_tag}")
                            image_count += 1
                    else:
                        new_content = _apply_direct_ref(content, ref, resolved)
                        if new_content != content:
                            Path(fpath).write_text(new_content)
                            latest_content[fpath] = new_content
                            print(f"  {fpath}: {ref} → {resolved}")
                            image_count += 1

        print(f"  {image_count} image(s) updated.")
        if warnings["flavored"]:
            print("\n=== Flavored tags (not matched against latest/stable/release) ===")
            for w in warnings["flavored"]:
                print(f"  {w}")
        if warnings["major_avail"]:
            print("\n=== New major versions available (staying within current series) ===")
            for w in warnings["major_avail"]:
                print(f"  {w}")
        if warnings["semver_fallback"]:
            print("\n=== Highest semver used (no floating tag match) ===")
            for w in warnings["semver_fallback"]:
                print(f"  {w}")
        if warnings["problematic"]:
            print("\n=== Images that could not be resolved ===")
            for p in warnings["problematic"]:
                print(f"  {p}")
        if warnings["digest_pin"]:
            print("\n=== Pinned by digest (no semver tags available) ===")
            for d in warnings["digest_pin"]:
                print(f"  {d}")

        print("\n" + ("Nothing to update." if DRY_RUN and image_count == 0 else
              "Done. Review changes with 'git diff' and run 'make validate'."))

    finally:
        _digest_pool.shutdown(wait=True)


if __name__ == "__main__":
    main()
