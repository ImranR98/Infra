"""YAML scanning, Helm chart updates, and file mutation."""
import re
import time
import yaml
from pathlib import Path
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed

from . import PURE_SEMVER_RE, PURE_NUMERIC_LINE_RE, ChartResult, SEMVER_TRIPLE_RE, DIRECT_IMAGE_RE, _SKIP_KEYS
from .registry import run, http_get, skopeo_tags
from .resolver import resolve_image, _get_pinned_lines, _is_pinned, _get_compiled

# Set by main() before calling update functions
FILTER = None
DRY_RUN = False
VERBOSE = False
RESOLVE_LIMIT = None
PARALLELISM = 4
INNER_POOL_SIZE = 4

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


def find_image_refs(components):
    """Scan all YAML files under the k3s component dir for unpinned image references.

    Returns (results, file_contents) where:
    - results: list of ("direct"|"values", filepath, ref) tuples
    - file_contents: {filepath: content} dict for later use in updates
    """
    results = []
    file_contents = {}
    for f in sorted(components.rglob("*.yaml")) + sorted(components.rglob("*.yml")):
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


def update_helm_charts(components):
    """Find and update all HelmChart CRDs across all YAML files."""
    print("\n=== Helm Charts ===")
    chart_files = []
    for f in sorted(components.rglob("*.yaml")) + sorted(components.rglob("*.yml")):
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


