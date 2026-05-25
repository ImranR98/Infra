#!/usr/bin/env python3
"""Update Traefik plugin versions across Compose and K3s stacks."""

import json
import os
import re
import subprocess
import sys
from urllib.request import Request, urlopen


ATLAS_ROOT = os.environ.get("ATLAS_ROOT", "")
TARGET = os.environ.get("TARGET", "")

if not TARGET:
    print("Error: TARGET must be set.", file=sys.stderr)
    sys.exit(1)


def _github_latest_tag(url: str) -> str | None:
    if "github.com/" not in url:
        print(f"  UNSUPPORTED PLUGIN: {url}", file=sys.stderr)
        return None
    api_url = f"https://api.github.com/repos/{url.split('github.com/')[1]}/releases/latest"
    try:
        req = Request(api_url, headers={"Accept": "application/json"})
        with urlopen(req, timeout=30) as resp:
            return json.loads(resp.read()).get("tag_name")
    except Exception as e:
        print(f"  Failed to fetch releases for {api_url}: {e}", file=sys.stderr)
        return None


def _find_plugin_entries(text: str) -> list[dict]:
    """Find plugin modulename=URL entries and their version lines."""
    pattern = re.compile(r'\.plugins\.([^.]+)\.modulename=([^\s"]+)')
    entries = []
    for match in pattern.finditer(text):
        name = match.group(1)
        url = match.group(2)
        ver_match = re.search(rf'\.plugins\.{name}\.version=([^\s"]+)', text)
        version = ver_match.group(1) if ver_match else None
        entries.append({"name": name, "url": url, "version": version})
    return entries


def _update_compose_stack(compose_file: str) -> None:
    try:
        result = subprocess.run(
            ["yq", ".services.traefik.command", compose_file],
            capture_output=True, text=True, timeout=30
        )
    except Exception as e:
        print(f"  Failed to parse compose file: {e}", file=sys.stderr)
        return

    command_text = result.stdout.strip()
    if not command_text or command_text == "null":
        return

    entries = _find_plugin_entries(command_text)
    if not entries:
        return

    with open(compose_file) as f:
        content = f.read()

    updated = False
    for entry in entries:
        if entry["version"] is None:
            continue
        latest = _github_latest_tag(entry["url"])
        if latest is None:
            continue
        if entry["version"] == latest:
            print(f"  {entry['name']} already latest ({latest})")
            continue
        print(f"  {entry['name']}: {entry['version']} -> {latest}")
        content = re.sub(
            rf"\.plugins\.{entry['name']}\.version={re.escape(entry['version'])}",
            f".plugins.{entry['name']}.version={latest}",
            content
        )
        updated = True

    if updated:
        with open(compose_file, "w") as f:
            f.write(content)
        print("  Updated compose file. Restart Traefik to apply.")


def _update_k3s_stack(traefik_yaml: str) -> None:
    try:
        with open(traefik_yaml) as f:
            content = f.read()
    except Exception as e:
        print(f"  Failed to read {traefik_yaml}: {e}", file=sys.stderr)
        return

    # Extract valuesContent from HelmChartConfig
    import yaml as yaml_lib
    try:
        for doc in yaml_lib.safe_load_all(content):
            if isinstance(doc, dict) and doc.get("kind") == "HelmChartConfig":
                values = doc.get("spec", {}).get("valuesContent", "")
                break
        else:
            return
    except Exception:
        return

    if not values:
        return

    entries = _find_plugin_entries(values)
    if not entries:
        return

    updated = False
    for entry in entries:
        if entry["version"] is None:
            continue
        latest = _github_latest_tag(entry["url"])
        if latest is None:
            continue
        if entry["version"] == latest:
            print(f"  {entry['name']} already latest ({latest})")
            continue
        print(f"  {entry['name']}: {entry['version']} -> {latest}")
        content = re.sub(
            rf"\.plugins\.{entry['name']}\.version=\S+",
            f".plugins.{entry['name']}.version={latest}",
            content
        )
        updated = True

    if updated:
        with open(traefik_yaml, "w") as f:
            f.write(content)
        print("  Updated K3s traefik.yaml. Restart Traefik to apply.")


def main() -> None:
    args = sys.argv[1:]
    target = args[0] if args else TARGET

    compose_file = os.path.join(ATLAS_ROOT, "targets", target, "compose", "compose.yaml")
    if os.path.isfile(compose_file):
        print(f"=== Compose: {target} ===")
        _update_compose_stack(compose_file)

    traefik_yaml = os.path.join(ATLAS_ROOT, "targets", target, "k3s", "traefik", "traefik.yaml")
    if os.path.isfile(traefik_yaml):
        print(f"=== K3s: {target} ===")
        _update_k3s_stack(traefik_yaml)


if __name__ == "__main__":
    main()
