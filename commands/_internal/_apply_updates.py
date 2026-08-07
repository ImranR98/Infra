#!/usr/bin/env python3
"""Apply updates discovered by Renovate to YAML files.

Reads Renovate's debug log from stdin and applies version updates
to source files, respecting # PRESERVE_FULL and # PRESERVE_MAJOR annotations.

Usage: python3 _apply_updates.py [--dry-run] [--target=<name>] < renovate-log.json
"""
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

INFRA_ROOT = Path(os.environ.get("INFRA_ROOT", ".")).resolve()

FLOATING_TAGS = ("latest", "stable", "release")

_DIGEST_CACHE: dict[tuple[str, str], str | None] = {}


def _get_manifest_digest(image: str, tag: str) -> str | None:
    """Query an OCI registry for the manifest digest of image:tag.

    Returns the full digest string (e.g. "sha256:abcd1234...") or None
    on any failure (network, auth, missing image, etc.).
    """
    cache_key = (image, tag)
    if cache_key in _DIGEST_CACHE:
        return _DIGEST_CACHE[cache_key]

    parsed = image.split("/")
    host_present = "." in parsed[0] or ":" in parsed[0]
    host = parsed[0] if host_present else "docker.io"
    if host_present:
        image_name = "/".join(parsed[1:])
    else:
        image_name = image
    if "/" not in image_name:
        image_name = "library/" + image_name

    registry_host = "registry-1.docker.io" if host == "docker.io" else host

    ctx = ssl.create_default_context()

    try:
        v2_url = f"https://{registry_host}/v2/"
        req = urllib.request.Request(v2_url, method="HEAD")
        resp = urllib.request.urlopen(req, context=ctx, timeout=15)
        auth_header = resp.getheader("Www-Authenticate", "")
        resp.close()
    except urllib.error.HTTPError as e:
        auth_header = e.headers.get("Www-Authenticate", "")
    except Exception:
        _DIGEST_CACHE[cache_key] = None
        return None

    m = re.search(
        r'Bearer\s+realm="([^"]+)"(?:,\s*service="([^"]+)")?',
        auth_header,
    )
    if not m:
        _DIGEST_CACHE[cache_key] = None
        return None

    realm = m.group(1)
    service = m.group(2) or host

    try:
        scope = f"repository:{image_name}:pull"
        token_url = f"{realm}?service={service}&scope={scope}"
        req = urllib.request.Request(token_url)
        resp = urllib.request.urlopen(req, context=ctx, timeout=15)
        token_data = json.loads(resp.read().decode())
        token = token_data.get("token", token_data.get("access_token", ""))
        resp.close()

        if not token:
            _DIGEST_CACHE[cache_key] = None
            return None

        manifest_url = f"https://{registry_host}/v2/{image_name}/manifests/{tag}"
        req = urllib.request.Request(manifest_url, method="HEAD")
        req.add_header("Authorization", f"Bearer {token}")
        req.add_header("Accept",
                       "application/vnd.docker.distribution.manifest.v2+json, "
                       "application/vnd.oci.image.manifest.v1+json, "
                       "application/vnd.docker.distribution.manifest.list.v2+json, "
                       "application/vnd.oci.image.index.v1+json")
        resp = urllib.request.urlopen(req, context=ctx, timeout=15)
        digest = resp.getheader("Docker-Content-Digest", "")
        resp.close()

        if digest:
            _DIGEST_CACHE[cache_key] = digest
            return digest
    except Exception:
        pass

    _DIGEST_CACHE[cache_key] = None
    return None


def _parse_flag(flag):
    for arg in sys.argv:
        if arg.startswith(flag + "="):
            return arg.split("=", 1)[1]
        if arg == flag:
            return None
    return None


def _has_flag(flag):
    return flag in sys.argv


def _apply_file(package_file, deps, dry_run=False):
    fpath = INFRA_ROOT / package_file
    if not fpath.exists():
        print(f"  WARNING: {package_file} not found, skipping")
        return

    content = fpath.read_text()
    changed = False

    for dep in deps:
        updates = dep.get("updates", [])
        if not updates:
            continue
        update = updates[0]
        new_value = update.get("newValue", "")
        new_digest = update.get("newDigest", "")
        current_val = dep.get("currentValue", "")

        dep_name = dep.get("depName", "")
        old_str = dep.get("replaceString", "")

        if not new_value or not current_val or not old_str:
            continue

        idx = content.find(old_str)
        if idx >= 0:
            line_start = content.rfind('\n', 0, idx) + 1
            line_end = content.find('\n', idx)
            if line_end < 0:
                line_end = len(content)
            line = content[line_start:line_end]
            if "# PRESERVE_FULL" in line:
                print(f"  {dep_name}: skipped (# PRESERVE_FULL)")
                continue
            if update.get("updateType") == "major" and "# PRESERVE_MAJOR" in line:
                print(f"  {dep_name}: skipped major update (# PRESERVE_MAJOR)")
                continue

        new_str = old_str.replace(current_val, new_value, 1)
        if new_digest and current_val in FLOATING_TAGS:
            new_str = re.sub(r'@sha256:\S+$', '', new_str)
            new_str = new_str + "@" + new_digest

        if old_str == new_str:
            continue

        if old_str and old_str in content:
            content = content.replace(old_str, new_str, 1)
            print(f"  {dep_name}: {dep.get('currentValue', '?')} -> {new_value}{'@'+new_digest if new_digest else ''}")
            changed = True
        else:
            print(f"  {dep_name}: could not find '{old_str}' in file, skipping")

    if changed and not dry_run:
        fpath.write_text(content)
        print(f"  Updated {package_file}")


def _update_floating_digests(target: str | None, dry_run: bool) -> None:
    """Scan K3s YAML files for floating-tag images with digests, re-check
    the current manifest digest, and update if it changed."""
    if not target:
        return

    k3s_root = INFRA_ROOT / "targets" / target / "k3s"
    if not k3s_root.is_dir():
        return

    print("\n=== Checking floating-tag digests ===")

    _floating = "|".join(FLOATING_TAGS)
    IMAGE_RE = re.compile(
        r'^(\s*image:\s*)(?P<dep>[^\s@:"\']+):'
        rf'(?P<tag>(?:{_floating}))'
        r'(@(?P<digest>sha256:[a-f0-9]{64}))',
        re.MULTILINE,
    )

    yaml_files = sorted(k3s_root.rglob("*.yaml"))

    for yf in yaml_files:
        content = yf.read_text()
        file_content = content
        changed = False
        rel_path = str(yf.relative_to(INFRA_ROOT))

        for match in IMAGE_RE.finditer(content):
            dep = match.group("dep")
            tag = match.group("tag")
            old_digest = match.group("digest")
            if not old_digest:
                continue

            line_start = content.rfind('\n', 0, match.start()) + 1
            line_end = content.find('\n', match.end())
            line = content[line_start:line_end] if line_end >= 0 else content[line_start:]

            if "# PRESERVE_FULL" in line:
                print(f"  {dep}:{tag} skipped (# PRESERVE_FULL)")
                continue
            if "# PRESERVE_MAJOR" in line:
                continue

            current_digest = _get_manifest_digest(dep, tag)
            if not current_digest:
                print(f"  {dep}:{tag} WARNING: could not query registry, skipping")
                continue

            if current_digest == old_digest:
                continue

            print(f"  {dep}:{tag} {old_digest[:15]}... -> {current_digest[:15]}...")
            file_content = file_content.replace(
                "@" + old_digest, "@" + current_digest
            )
            changed = True

        if changed and not dry_run:
            yf.write_text(file_content)
            print(f"  Updated {rel_path}")
        elif changed:
            print(f"  [DRY RUN] would update {rel_path}")


def main():
    dry_run = _has_flag("--dry-run")
    target = _parse_flag("--target")

    log_line = None

    for line in sys.stdin:
        stripped = line.strip()
        if not stripped:
            continue
        try:
            data = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        msg = data.get("msg", "")
        if "packageFiles with updates" in str(msg):
            log_line = data
            break

    if not log_line:
        print("No packageFiles with updates found in Renovate output.")
    else:
        config = log_line.get("config", {})
        if not config:
            print("No config in packageFiles output.")
        else:
            _seen = set()

            for manager, file_list in config.items():
                if not isinstance(file_list, list):
                    continue
                for entry in file_list:
                    if not isinstance(entry, dict):
                        continue
                    deps = entry.get("deps", [])
                    if not deps:
                        continue
                    has_updates = any(d.get("updates") for d in deps)
                    if not has_updates:
                        continue
                    pkg_file = entry.get("packageFile", "")
                    if not pkg_file:
                        continue
                    if target and not pkg_file.startswith(f"targets/{target}/"):
                        continue
                    dedup_key = (pkg_file, tuple(d.get("depName","") for d in deps))
                    if dedup_key in _seen:
                        continue
                    _seen.add(dedup_key)
                    print(f"\n=== {pkg_file} ===")
                    _apply_file(pkg_file, deps, dry_run)

    _update_floating_digests(target, dry_run)

    if dry_run:
        print("\n=== DRY RUN: no files were modified ===")


if __name__ == "__main__":
    main()
