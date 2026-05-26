#!/usr/bin/env python3
"""Apply updates discovered by Renovate to YAML files.

Reads Renovate's debug log from stdin, finds all dependencies with
available updates, and applies them to the source files using the
autoReplaceStringTemplate provided by Renovate.

Usage: RENOVATE_LOG=<file> python3 _apply_updates.py [--dry-run]
"""
import json
import os
import re
import sys
from pathlib import Path

ATLAS_ROOT = Path(os.environ.get("ATLAS_ROOT", ".")).resolve()


def _render_template(template, dep_name, new_value, new_digest=""):
    """Render Renovate's autoReplaceStringTemplate (Handlebar-ish).
    Supports: {{depName}}, {{newValue}}, {{newDigest}}, {{#if ...}}{{/if}}"""
    result = template

    def _if(repl, cond, body):
        if cond:
            return re.sub(r"\{\{#if\s+\w+\}\}" + re.escape(body) + r"\{\{/if\}\}", body, repl)
        return re.sub(r"\{\{#if\s+\w+\}\}" + re.escape(body) + r"\{\{/if\}\}", "", repl)

    result = result.replace("{{depName}}", dep_name)

    nv = new_value or ""
    result = _if(result, bool(nv), "{{newValue}}")
    result = result.replace("{{newValue}}", nv)

    nd = new_digest or ""
    result = _if(result, bool(nd), "{{newDigest}}")
    result = result.replace("{{newDigest}}", nd)

    result = result.replace("{{#if newValue}}", "").replace("{{#if newDigest}}", "")
    result = re.sub(r"\{\{/if\}\}", "", result)

    return result


def _apply_file(package_file, deps, dry_run=False):
    fpath = ATLAS_ROOT / package_file
    if not fpath.exists():
        print(f"  WARNING: {package_file} not found, skipping")
        return

    content = fpath.read_text()
    original = content
    changed = False

    for dep in deps:
        updates = dep.get("updates", [])
        if not updates:
            continue
        update = updates[0]
        new_value = update.get("newValue", "")
        new_digest = update.get("newDigest", "")

        dep_name = dep.get("depName", "")
        template = dep.get("autoReplaceStringTemplate", "{{depName}}:{{newValue}}")
        old_str = dep.get("replaceString", "")
        new_str = _render_template(template, dep_name, new_value, new_digest)

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


def main():
    dry_run = "--dry-run" in sys.argv
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
        return

    config = log_line.get("config", {})
    if not config:
        print("No config in packageFiles output.")
        return

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
            dedup_key = (pkg_file, tuple(d.get("depName","") for d in deps))
            if dedup_key in _seen:
                continue
            _seen.add(dedup_key)
            print(f"\n=== {pkg_file} ===")
            _apply_file(pkg_file, deps, dry_run)

    if dry_run:
        print("\n=== DRY RUN: no files were modified ===")


if __name__ == "__main__":
    main()
