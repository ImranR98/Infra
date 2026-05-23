#!/usr/bin/env python3
"""Pin Helm chart versions and container image tags to specific versions.

This script scans all YAML files under the k3s component dir and pins floating container
image references (e.g. "nginx:latest") to specific semver tags (e.g. "nginx:1.30.0-alpine").
It also updates Helm chart versions in helmchart.yaml files.

== How it works ==

1. HELM CHARTS (update_helm_charts):
   - Scans all YAML files under the k3s component dir for `kind: HelmChart` CRDs
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

_path = Path(__file__).resolve()
ATLAS_ROOT = Path(os.environ.get("ATLAS_ROOT", ""))
if not str(ATLAS_ROOT):
    for parent in _path.parents:
        if (parent / "lib" / "common.sh").exists():
            ATLAS_ROOT = parent
            break
    if not str(ATLAS_ROOT):
        print("Error: cannot find ATLAS_ROOT. Set ATLAS_ROOT or run via atlas.sh.", file=sys.stderr)
        sys.exit(1)
TARGET = os.environ.get("TARGET", "")
if not TARGET:
    print("Error: TARGET must be set. Run via atlas.sh.", file=sys.stderr)
    sys.exit(1)
COMPONENTS = ATLAS_ROOT / "targets" / TARGET / "k3s"
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

# Insert __path for package imports
sys.path.insert(0, str(ATLAS_ROOT / "lib"))
from k3s import RefInfo, ChartResult, ResolveResult, CAT_RESOLVED, CAT_FLAVORED, CAT_MAJOR_AVAIL, CAT_SEMVER_FALLBACK, CAT_ERROR, CAT_NO_CHANGE, CAT_DIGEST_PIN
from k3s.registry import run, http_get, skopeo_tags, skopeo_digest, _registry_v2_digest
from k3s.resolver import semver_key, is_prerelease, is_flavored, highest_stable, parse_ref, resolve_image, _semver_key_cached, _get_compiled, _get_suffix_patterns
from k3s.updater import _iter_repo_tag_pairs, find_image_refs, _apply_direct_ref, _apply_values_tag, _resolve_helm_chart, _chart_label, update_helm_charts, highest_semver_string
import k3s.resolver as _resolver
import k3s.updater as _updater

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


def main():
    global DRY_RUN, VERBOSE, FLOAT_TAG_RESOLVE_LIMIT, FILTER, _digest_pool

    DRY_RUN, VERBOSE, FLOAT_TAG_RESOLVE_LIMIT, FILTER = _parse_args()
    _digest_pool = ThreadPoolExecutor(max_workers=INNER_POOL_SIZE)
    # Propagate to library modules
    _resolver._digest_pool = _digest_pool
    _resolver.FLOAT_TAG_RESOLVE_LIMIT = FLOAT_TAG_RESOLVE_LIMIT
    _resolver.PARALLELISM = PARALLELISM
    _resolver.INNER_POOL_SIZE = INNER_POOL_SIZE
    _resolver.VERBOSE = VERBOSE
    _updater.DRY_RUN = DRY_RUN
    _updater.VERBOSE = VERBOSE
    _updater.FILTER = FILTER
    _updater.PARALLELISM = PARALLELISM
    import k3s.registry as _registry
    _registry.VERBOSE = VERBOSE
    _updater.INNER_POOL_SIZE = INNER_POOL_SIZE

    try:
        print("Update Versions")
        if DRY_RUN:
            print("=== DRY RUN ===")

        update_helm_charts(COMPONENTS)

        print("\n=== Container Images ===")
        refs, file_contents = find_image_refs(COMPONENTS)

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
              "Done. Review changes with 'git diff' and run './atlas.sh <target> validate'."))

    finally:
        if _digest_pool: _digest_pool.shutdown(wait=True)


if __name__ == "__main__":
    main()
