"""Image ref parsing and semver-based resolution."""
import functools
import os
import re
from concurrent.futures import as_completed
import time
from concurrent.futures import as_completed
from collections import defaultdict

from . import (
    FLAVOR_RE, SEMVER_TAG_RE, SUFFIX_DIGIT_RE, PRERELEASE_RE,
    PURE_SEMVER_RE, PURE_NUMERIC_LINE_RE, RefInfo, ResolveResult,
    CAT_SEMVER_FALLBACK, CAT_FLAVORED, CAT_MAJOR_AVAIL, CAT_ERROR,
    CAT_NO_CHANGE, CAT_DIGEST_PIN, CAT_RESOLVED,
)
from .registry import http_get, skopeo_digest, skopeo_tags

# Set by main() before calling resolve functions
FLOAT_TAG_RESOLVE_LIMIT = 10
PARALLELISM = 4
INNER_POOL_SIZE = 4
VERBOSE = False

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



# Module-level caches
_pinned_cache = {}
_digest_pool = None

_compiled_re = {}

# Architecture detection for filtering arch-specific image tags
_HOST_ARCH = os.uname().machine
if _HOST_ARCH in ("x86_64", "amd64"):
    _EXPECTED_ARCH_SUFFIXES = ("-amd64",)
elif _HOST_ARCH in ("aarch64", "arm64"):
    _EXPECTED_ARCH_SUFFIXES = ("-arm64v8", "-aarch64")
else:
    _EXPECTED_ARCH_SUFFIXES = ()
_ARCH_SUFFIX_RE = re.compile(r"-(amd64|arm64v8|aarch64|armv6|armv7|i386|s390x|ppc64le)$")
