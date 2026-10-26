#!/usr/bin/env python3
"""Append proposed Falco exception blocks to custom-rules.yaml.

Input is the YAML list produced by falco-events.py --format yaml. The script:
  - validates every exception (fields/comps/values lengths),
  - skips exceptions already covered by an existing exception for that rule,
  - appends the remaining blocks without rewriting the existing comments,
  - re-parses the whole file before writing it.

It never deploys. Run scripts/validate.sh and helm upgrade afterwards.
"""

import argparse
import datetime
import sys
from pathlib import Path

import yaml

DEFAULT_PATH = Path("targets/srv0/k3s-base/files/falco/custom-rules.yaml")


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def load_yaml(path):
    try:
        data = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        fail(f"{path}: invalid YAML: {exc}")
    if data is None:
        return []
    if not isinstance(data, list):
        fail(f"{path}: expected a YAML list of rule overrides")
    return data


def validate_block(block, index):
    if not isinstance(block, dict):
        fail(f"proposal #{index}: expected a mapping")
    rule = block.get("rule")
    if not isinstance(rule, str) or not rule:
        fail(f"proposal #{index}: missing rule")
    exceptions = block.get("exceptions")
    if not isinstance(exceptions, list) or not exceptions:
        fail(f"proposal #{index} ({rule}): missing exceptions list")
    for ex in exceptions:
        if not isinstance(ex, dict):
            fail(f"proposal #{index} ({rule}): exception must be a mapping")
        name = ex.get("name")
        fields = ex.get("fields")
        comps = ex.get("comps", ["="] * len(fields or []))
        values = ex.get("values")
        if not isinstance(name, str) or not name:
            fail(f"proposal #{index} ({rule}): exception missing name")
        if not isinstance(fields, list) or not fields:
            fail(f"{rule}/{name}: fields must be a non-empty list")
        if not isinstance(comps, list) or len(comps) != len(fields):
            fail(f"{rule}/{name}: comps must have the same length as fields")
        if not isinstance(values, list) or not values:
            fail(f"{rule}/{name}: values must be a non-empty list of rows")
        for row in values:
            if not isinstance(row, list) or len(row) != len(fields):
                fail(f"{rule}/{name}: each values row must have {len(fields)} items")
        override = block.get("override", {"exceptions": "append"})
        if override != {"exceptions": "append"}:
            fail(f"{rule}/{name}: only override.exceptions=append is supported")


def existing_scopes(rule_blocks, rule):
    scopes = []
    for block in rule_blocks:
        if block.get("rule") != rule:
            continue
        for ex in block.get("exceptions", []):
            fields = ex.get("fields") or []
            comps = ex.get("comps") or ["="] * len(fields)
            rows = ex.get("values") or []
            for row in rows:
                scopes.append(list(zip(fields, comps, row)))
    return scopes


def covered_by(existing, proposed_fields, proposed_comps, proposed_row):
    """True if an existing exception covers the proposed scope.

    The existing exception may be broader (fewer fields, startswith instead of
    exact); if it covers the proposed values, a second exception adds no value.
    """
    proposed = dict(zip(proposed_fields, zip(proposed_comps, proposed_row)))
    for field, comp, value in existing:
        if field not in proposed:
            return False
        pcomp, pvalue = proposed[field]
        if comp == "=":
            if str(pvalue) != str(value):
                return False
        elif comp == "startswith":
            if pcomp not in ("=", "startswith"):
                return False
            if not str(pvalue).startswith(str(value)):
                return False
        else:
            if (pcomp, str(pvalue)) != (comp, str(value)):
                return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="YAML list from falco-events.py --format yaml")
    parser.add_argument("--path", default=str(DEFAULT_PATH), help=f"custom rules path (default: {DEFAULT_PATH})")
    parser.add_argument("--dry-run", action="store_true", help="show what would be appended")
    args = parser.parse_args()

    path = Path(args.path)
    if not path.exists():
        fail(f"{path} does not exist")
    existing = load_yaml(path)
    proposals = load_yaml(Path(args.input))
    if not isinstance(proposals, list) or not proposals:
        fail(f"{args.input}: expected a non-empty YAML list")

    for index, block in enumerate(proposals):
        validate_block(block, index)

    additions = []
    for block in proposals:
        scopes = existing_scopes(existing, block["rule"])
        keep = []
        for ex in block["exceptions"]:
            fields = ex["fields"]
            comps = ex.get("comps", ["="] * len(fields))
            rows = ex["values"]
            rows_covered = all(
                any(covered_by(scope, fields, comps, row) for scope in scopes)
                for row in rows
            )
            if rows_covered:
                print(f"skip {block['rule']}/{ex['name']}: already covered", file=sys.stderr)
                continue
            keep.append(ex)
        if keep:
            additions.append({"rule": block["rule"], "exceptions": keep,
                              "override": block.get("override", {"exceptions": "append"})})

    if not additions:
        print("nothing to add")
        return

    header = (
        f"\n# Added by falco-exception-triage"
        f" ({datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d')})\n"
    )
    body = yaml.safe_dump(additions, sort_keys=False, default_flow_style=False, width=1000)

    if args.dry_run:
        print(header + body)
        return

    original = path.read_text()
    updated = original.rstrip() + "\n" + header + body
    try:
        yaml.safe_load(updated)
    except yaml.YAMLError as exc:
        fail(f"refusing to write: result is invalid YAML: {exc}")

    path.write_text(updated)
    print(f"appended {sum(len(b['exceptions']) for b in additions)} exception(s) to {path}")
    print("next: python3 -c 'import yaml; yaml.safe_load(open(...))' && bash scripts/validate.sh srv0")


if __name__ == "__main__":
    main()
