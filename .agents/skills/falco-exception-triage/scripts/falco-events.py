#!/usr/bin/env python3
"""Query Falco events from Loki and group them into exception candidates.

The script is intentionally read-only. It never prints raw command lines or
Falco JSON: command lines are redacted before they reach stdout, and the
summary only shows the fields needed to scope an exception.

Examples:
  ./falco-events.py --since 24h --priority Warning,Critical
  ./falco-events.py --since 12h --app dscpln,task-runner
  ./falco-events.py --from 2026-10-25T00:00:00Z --to 2026-10-26T08:00:00Z
  ./falco-events.py --since 6h --format yaml
"""

import argparse
import collections
import datetime
import json
import re
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

LOKI_NAMESPACE = "base"
LOKI_SERVICE = "loki"
FALCO_QUERY = '{namespace="base", app="falco", container="falco"} | json | __error__=""'

# These are test/one-off namespaces and pods; they should not produce
# production exceptions unless the operator explicitly asks (--include-test).
TEST_PREFIXES = (
    "falco-selftest-",
    "falco-api-selftest",
    "falco-alert-test",
    "falco-eg-sandbox",
    "event-generator",
)

PRIORITIES = ("Emergency", "Alert", "Critical", "Error", "Warning", "Notice", "Informational", "Debug")
DEFAULT_PRIORITIES = ("Emergency", "Alert", "Critical", "Error", "Warning")

# Rules where fd.name is worth adding to an exception (files/paths).
FILE_RULES = {
    "Read sensitive file untrusted",
    "Read sensitive file trusted after startup",
    "Directory traversal monitored file read",
    "Search private keys or passwords",
    "Write below etc",
    "Write below root",
    "Write below monitored dir",
    "Write below binary dir",
    "Create symlink over sensitive files",
    "Create hardlink over sensitive files",
}


def eprint(*args):
    print(*args, file=sys.stderr)


def parse_time(value, default):
    if value is None:
        return default
    value = value.strip()
    if re.fullmatch(r"\d+[smhdw]", value):
        n = int(value[:-1])
        mult = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}[value[-1]]
        return default - n * mult
    try:
        return float(value)
    except ValueError:
        pass
    try:
        dt = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise SystemExit(f"cannot parse time {value!r}: {exc}") from exc
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.timestamp()


def fmt_time(epoch):
    if epoch > 1e12:
        epoch /= 1e9
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%m-%d %H:%M:%S")


def redact(text):
    if not text:
        return ""
    text = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1<redacted>", text)
    text = re.sub(r"(?i)(authorization[=:]\s*)[^\s]+", r"\1<redacted>", text)
    text = re.sub(
        r"(?i)((?:token|password|passwd|secret|api[_-]?key)\s*[=:]\s*)[^\s]+",
        r"\1<redacted>",
        text,
    )
    text = re.sub(
        r"(?i)(--(?:token|password|passwd|secret|api[-_]?key)[ =])[^\s]+",
        r"\1<redacted>",
        text,
    )
    return text[:200]


def free_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class Loki:
    def __init__(self, url=None):
        self.proc = None
        if url:
            self.url = url.rstrip("/")
            return
        port = free_port()
        self.url = f"http://127.0.0.1:{port}"
        eprint(f"opening Loki port-forward on {port} ...")
        self.proc = subprocess.Popen(
            [
                "kubectl", "-n", LOKI_NAMESPACE, "port-forward",
                "--address", "127.0.0.1", f"svc/{LOKI_SERVICE}", f"{port}:3100",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 15
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise SystemExit(
                    "kubectl port-forward exited; is the kubeconfig unlocked? "
                    "Run scripts/kubeconfig-unlock.sh in another terminal."
                )
            try:
                with urllib.request.urlopen(f"{self.url}/ready", timeout=1) as response:
                    if response.status == 200:
                        return
            except Exception:
                time.sleep(0.25)
        self.close()
        raise SystemExit("timed out waiting for Loki")

    def close(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def query_range(self, query, start, end, limit):
        params = urllib.parse.urlencode(
            {
                "query": query,
                "start": int(start * 1_000_000_000),
                "end": int(end * 1_000_000_000),
                "limit": limit,
                "direction": "backward",
            }
        )
        url = f"{self.url}/loki/api/v1/query_range?{params}"
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")[:500]
            raise SystemExit(f"Loki query failed ({exc.code}): {body}") from exc


def extract(event):
    fields = event.get("output_fields") or {}
    return {
        "priority": event.get("priority") or "",
        "rule": event.get("rule") or "",
        "hostname": event.get("hostname") or "",
        "output": event.get("output") or "",
        "ns": fields.get("k8s.ns.name") or "",
        "pod": fields.get("k8s.pod.name") or "",
        "container": fields.get("container.name") or "",
        "image": fields.get("container.image.repository") or "",
        "proc": fields.get("proc.name") or "",
        "exe": fields.get("proc.exepath") or "",
        "pname": fields.get("proc.pname") or "",
        "cmdline": redact(fields.get("proc.cmdline") or ""),
        "file": fields.get("fd.name") or "",
        "user": fields.get("user.name") or "",
    }


def pod_prefix(pod):
    if not pod:
        return ""
    for prefix in TEST_PREFIXES + ("helm-install-", "immich-seed-", "crowdsec-cert-roll-", "falco-alert-test-"):
        if pod.startswith(prefix):
            return prefix
    for pattern in (
        r"^(.+)-[a-z0-9]{8,10}-[a-z0-9]{5}$",   # Deployment ReplicaSet
        r"^(.+)-\d{5,10}-[a-z0-9]{5}$",         # CronJob timestamp + random
        r"^(.+)-[a-z0-9]{5}$",                  # Job random suffix
    ):
        match = re.match(pattern, pod)
        if match:
            return match.group(1) + "-"
    return pod


def is_test_event(event):
    haystack = f"{event['ns']} {event['pod']} {event['container']}".lower()
    return any(prefix in haystack for prefix in TEST_PREFIXES)


def suggestion(group):
    """Return (fields, comps, values, scope) for a grouped event."""
    rule = group["rule"]
    if group["is_host"]:
        fields = ["container.name", "proc.name"]
        comps = ["=", "="]
        values = [["host", group["proc"]]]
        return fields, comps, values, f"host + proc.name={group['proc'] or '*'}"

    fields = ["k8s.ns.name", "k8s.pod.name", "proc.name"]
    comps = ["=", "startswith", "="]
    values = [[group["ns"], group["prefix"], group["proc"]]]
    if group["file"] and rule in FILE_RULES:
        fields.append("fd.name")
        comps.append("=")
        values[0].append(group["file"])
    scope = ", ".join(
        f"{field} startswith {value}" if comp == "startswith" else f"{field}={value}"
        for field, comp, value in zip(fields, comps, values[0])
    )
    return fields, comps, values, scope


def slug(text):
    value = re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")
    return value[:64] or "exception"


def propose_blocks(groups):
    """Build Falco rule-override blocks for non-test groups."""
    blocks = []
    used = set()
    for group in groups:
        if group["is_test"]:
            continue
        fields, comps, values, _ = suggestion(group)
        name = slug(f"{group['rule']}_{group['prefix'] or group['proc'] or 'host'}")
        candidate = name
        n = 2
        while candidate in used:
            candidate = f"{name}_{n}"
            n += 1
        used.add(candidate)
        blocks.append(
            {
                "rule": group["rule"],
                "exceptions": [
                    {
                        "name": candidate,
                        "fields": fields,
                        "comps": comps,
                        "values": values,
                    }
                ],
                "override": {"exceptions": "append"},
            }
        )
    return blocks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since", help="relative window, e.g. 12h, 90m, 7d (default 24h)")
    parser.add_argument("--from", dest="from_time", help="absolute start (ISO 8601 or epoch)")
    parser.add_argument("--to", dest="to_time", help="absolute end (ISO 8601 or epoch)")
    parser.add_argument("--app", help="comma-separated substrings matched against namespace, pod, image, process, output")
    parser.add_argument("--namespace", help="restrict to an event namespace")
    parser.add_argument("--priority", default=",".join(DEFAULT_PRIORITIES),
                        help=f"comma-separated priorities, or 'all' (default: {','.join(DEFAULT_PRIORITIES)})")
    parser.add_argument("--rule", help="regexp matched against the Falco rule name")
    parser.add_argument("--include-test", action="store_true", help="include falco-selftest/event-generator events")
    parser.add_argument("--format", choices=("summary", "json", "yaml"), default="summary")
    parser.add_argument("--limit", type=int, default=5000)
    parser.add_argument("--loki-url", help="use an existing Loki URL instead of port-forwarding")
    parser.add_argument("--verbose", action="store_true", help="show redacted command lines in the summary")
    args = parser.parse_args()

    now = time.time()
    if args.since and args.from_time:
        parser.error("--since and --from are mutually exclusive")
    start = parse_time(args.from_time, now - 24 * 3600)
    if args.since:
        start = parse_time(args.since, now)
    end = parse_time(args.to_time, now)
    if start >= end:
        parser.error("start must be before end")

    priorities = {p.lower() for p in args.priority.split(",")} if args.priority.lower() != "all" else {p.lower() for p in PRIORITIES}
    unknown = priorities - {p.lower() for p in PRIORITIES}
    if unknown:
        parser.error(f"unknown priority: {', '.join(sorted(unknown))}")
    app_filters = [a.strip().lower() for a in (args.app or "").split(",") if a.strip()]
    rule_re = re.compile(args.rule, re.I) if args.rule else None

    loki = Loki(args.loki_url)
    try:
        payload = loki.query_range(FALCO_QUERY, start, end, args.limit)
    finally:
        loki.close()

    streams = payload.get("data", {}).get("result", [])
    rows = []
    for stream in streams:
        for ts, line in stream.get("values", []):
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not event.get("rule"):
                continue
            ev = extract(event)
            if ev["priority"].lower() not in priorities:
                continue
            if rule_re and not rule_re.search(ev["rule"]):
                continue
            if args.namespace and ev["ns"] != args.namespace:
                continue
            if app_filters:
                haystack = " ".join(
                    [ev["ns"], ev["pod"], ev["image"], ev["proc"], ev["user"], ev["rule"], ev["output"]]
                ).lower()
                if not any(needle in haystack for needle in app_filters):
                    continue
            rows.append((int(ts), ev))

    if len(rows) >= args.limit:
        eprint(f"warning: hit --limit {args.limit}; narrow the time range or app filter")

    grouped = collections.defaultdict(list)
    for ts, ev in rows:
        host = ev["container"] == "host" or not ev["pod"]
        prefix = "" if host else pod_prefix(ev["pod"])
        key = (
            ev["priority"], ev["rule"], ev["hostname"], ev["ns"], prefix,
            ev["container"], ev["image"], ev["proc"], ev["file"],
        )
        grouped[key].append((ts, ev))

    groups = []
    for key, items in grouped.items():
        priority, rule, hostname, ns, prefix, container, image, proc, file = key
        items.sort()
        ev = items[0][1]
        group = {
            "priority": priority,
            "rule": rule,
            "hostname": hostname,
            "ns": ns,
            "prefix": prefix or (ev["pod"] if not (container == "host" or not ev["pod"]) else ""),
            "pod": ev["pod"],
            "pods": sorted({e["pod"] for _, e in items if e["pod"]})[:5],
            "container": container,
            "image": image,
            "proc": proc,
            "exe": ev["exe"],
            "pname": ev["pname"],
            "file": file,
            "user": ev["user"],
            "cmdline": ev["cmdline"],
            "count": len(items),
            "first": fmt_time(items[0][0]),
            "last": fmt_time(items[-1][0]),
            "is_host": container == "host" or not ev["pod"],
            "is_test": any(is_test_event(e) for _, e in items),
        }
        fields, comps, values, scope = suggestion(group)
        group["scope"] = scope
        group["fields"] = fields
        group["comps"] = comps
        group["values"] = values
        groups.append(group)

    groups.sort(
        key=lambda g: (
            PRIORITIES.index(g["priority"]) if g["priority"] in PRIORITIES else 99,
            -g["count"],
            g["rule"],
        )
    )

    if args.format == "json":
        print(json.dumps({"from": fmt_time(start), "to": fmt_time(end), "groups": groups}, indent=2, sort_keys=True))
        return

    if args.format == "yaml":
        for group in groups:
            if group["is_test"]:
                continue
            print(f"# {group['priority']}: {group['rule']} ({group['count']} events, {group['first']}..{group['last']})")
            print(f"# scope: {group['scope']}")
            for block in propose_blocks([group]):
                print(yaml_dump([block]), end="")
            print()
        return

    if not groups:
        print("no matching Falco events")
        return

    print(f"Falco events {fmt_time(start)} .. {fmt_time(end)} UTC")
    print(f"{'count':>5}  {'priority':10}  {'rule':42}  {'host':5}  {'ns':8}  {'pod prefix / proc':32}  {'file':18}  first..last")
    for group in groups:
        target = group["prefix"] or group["proc"] or "-"
        marker = " [test]" if group["is_test"] else ""
        print(
            f"{group['count']:5d}  {group['priority']:10}  {group['rule'][:42]:42}  "
            f"{group['hostname'][:5]:5}  {group['ns'][:8]:8}  {target[:32]:32}  "
            f"{(group['file'] or '-')[:18]:18}  {group['first']}..{group['last']}{marker}"
        )
        if args.verbose and group["cmdline"]:
            print(f"       cmd: {group['cmdline']}")
        print(f"       scope: {group['scope']}")


def yaml_dump(block):
    import yaml  # imported lazily so summary/json work without PyYAML

    return yaml.safe_dump(block, sort_keys=False, default_flow_style=False, width=1000)


if __name__ == "__main__":
    main()
