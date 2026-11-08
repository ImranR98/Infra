#!/bin/bash
# DESC: Pin an app repo's published GHCR image digest in the Infra repo. After
# the app's default-branch `publish` job has pushed :sha-<commit> and promoted
# :latest, resolve the promoted digest and update every tracked
# `ghcr.io/<owner>/<image>:<tag>@sha256:...` reference in the Infra tree.
# Optionally validate the touched targets and commit only the changed files.
# Uses the GitHub and GHCR APIs; never assumes an app checkout.
# Usage: pin-app-image.sh --repo <owner/repo> (--sha <merge-sha> | --digest <sha256:...>)
#          [--tag latest] [--image name[,name]] [--timeout 180] [--poll 10]
#          [--no-verify-latest] [--validate] [--dry-run] [--commit]
#          [--message <text>] [--root <path>]
# Exit: 0 updated/already pinned, 1 error, 2 no image mapping or no matching refs,
#       3 digest unavailable or not promoted, 4 validation failed.
set -euo pipefail

repo=""
sha=""
digest=""
tag="latest"
images=""
timeout=180
poll=10
verify_latest=1
validate=0
dry_run=0
commit=0
message=""
root=""

usage() {
    echo "Usage: $(basename "$0") --repo <owner/repo> (--sha <merge-sha> | --digest <sha256:...>)"
    echo "         [--tag latest] [--image name[,name]] [--timeout 180] [--poll 10]"
    echo "         [--no-verify-latest] [--validate] [--dry-run] [--commit]"
    echo "         [--message <text>] [--root <path>]"
    exit "${1:-1}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --sha) sha="${2:-}"; shift 2 ;;
        --digest) digest="${2:-}"; shift 2 ;;
        --tag) tag="${2:-}"; shift 2 ;;
        --image) images="${2:-}"; shift 2 ;;
        --timeout) timeout="${2:-}"; shift 2 ;;
        --poll) poll="${2:-}"; shift 2 ;;
        --no-verify-latest) verify_latest=0; shift ;;
        --validate) validate=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --commit) commit=1; shift ;;
        --message) message="${2:-}"; shift 2 ;;
        --root) root="${2:-}"; shift 2 ;;
        -h | --help) usage 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            ;;
    esac
done

[ -n "$repo" ] || usage
[ -n "$sha" ] || [ -n "$digest" ] || usage
case "$repo" in
    */*) ;;
    *)
        echo "Error: --repo must be owner/repo." >&2
        exit 1
        ;;
esac
case "$timeout" in '' | *[!0-9]*) echo "Error: --timeout must be an integer." >&2; exit 1 ;; esac
case "$poll" in '' | *[!0-9]*) echo "Error: --poll must be an integer." >&2; exit 1 ;; esac

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [ -z "$root" ]; then
    root="$(cd "$script_dir/../../../.." && pwd)"
fi
if [ ! -d "$root" ]; then
    echo "Error: root does not exist: $root" >&2
    exit 1
fi
root="$(cd "$root" && pwd)"

if [ -f "$root/config/VARS.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$root/config/VARS.env"
    set +a
fi
if [ -z "${GITHUB_TOKEN:-}" ] && [ -n "${RENOVATE_GITHUB_TOKEN:-}" ]; then
    GITHUB_TOKEN="$RENOVATE_GITHUB_TOKEN"
fi
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"

exec python3 - "$repo" "$sha" "$digest" "$tag" "$images" "$timeout" "$poll" \
    "$verify_latest" "$validate" "$dry_run" "$commit" "$message" "$root" <<'PY'
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

(
    repo,
    sha,
    digest_override,
    tag,
    images_arg,
    timeout_raw,
    poll_raw,
    verify_latest_raw,
    validate_raw,
    dry_run_raw,
    commit_raw,
    message,
    root,
) = sys.argv[1:]

timeout = int(timeout_raw)
poll = int(poll_raw)
verify_latest = verify_latest_raw == "1"
validate = validate_raw == "1"
dry_run = dry_run_raw == "1"
commit = commit_raw == "1"
token = os.environ.get("GITHUB_TOKEN", "")
api = "https://api.github.com"
owner, repo_name = repo.split("/", 1)
owner = owner.lower()

manifest_accept = (
    "application/vnd.oci.image.index.v1+json, "
    "application/vnd.oci.image.manifest.v1+json, "
    "application/vnd.docker.distribution.manifest.list.v2+json, "
    "application/vnd.docker.distribution.manifest.v2+json"
)


def fail(code, text):
    print(text, flush=True)
    sys.exit(code)


def api_get(path, attempt=1):
    url = f"{api}{path}"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "infra-pin-app-image",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code in (403, 429) and attempt < 4:
            time.sleep(5 * attempt)
            return api_get(path, attempt + 1)
        raise
    except Exception:
        if attempt >= 3:
            raise
        time.sleep(2)
        return api_get(path, attempt + 1)


def workflow_texts(branch):
    texts = []
    try:
        items = api_get(
            f"/repos/{repo}/contents/.github/workflows?ref={urllib.parse.quote(branch)}"
        )
    except Exception as exc:
        print(f"WARN cannot list workflows: {exc}", flush=True)
        return texts
    for item in items:
        name = item.get("name", "")
        if item.get("type") != "file" or not name.endswith((".yml", ".yaml")):
            continue
        try:
            data = api_get(
                f"/repos/{repo}/contents/{urllib.parse.quote(item['path'], safe='/')}"
                f"?ref={urllib.parse.quote(branch)}"
            )
        except Exception as exc:
            print(f"WARN cannot read {item['path']}: {exc}", flush=True)
            continue
        content = data.get("content")
        if not content:
            continue
        try:
            texts.append(base64.b64decode(content).decode("utf-8", "replace"))
        except Exception:
            continue
    return texts


def git_grep_files(image):
    pattern = rf"ghcr\.io/{re.escape(owner)}/{re.escape(image)}[:@]"
    proc = subprocess.run(
        ["git", "-C", root, "grep", "-l", "-I", "-E", pattern],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return []
    return [line for line in proc.stdout.splitlines() if line]


def resolve_images():
    if images_arg:
        return [name.strip().lower() for name in images_arg.split(",") if name.strip()]

    try:
        branch = api_get(f"/repos/{repo}")["default_branch"]
    except Exception as exc:
        fail(1, f"ERROR cannot read repo metadata for {repo}: {exc}")

    texts = workflow_texts(branch)
    base = repo_name.lower()
    candidates = {base, re.sub(r"[^a-z0-9]+", "-", base).strip("-")}
    candidates.add(base.replace("-", ""))
    candidates.add(re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "-", repo_name).lower())
    for text in texts:
        for match in re.finditer(
            r"ghcr\.io/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)", text
        ):
            if match.group(1).lower() == owner:
                candidates.add(match.group(2).lower())
        for match in re.finditer(
            r"(?im)^\s*IMAGE_NAME\s*:\s*['\"]?([A-Za-z0-9_.-]+)", text
        ):
            candidates.add(match.group(1).lower())
        for match in re.finditer(
            r"(?im)^\s*IMAGE\s*:\s*['\"]?ghcr\.io/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)",
            text,
        ):
            if match.group(1).lower() == owner:
                candidates.add(match.group(2).lower())
        for match in re.finditer(r"\$\{?owner\}?/([A-Za-z0-9_.-]+)", text):
            candidates.add(match.group(1).lower())
        if (
            "${GITHUB_REPOSITORY#" in text
            or "${repo}" in text
            or "${name}" in text
        ):
            candidates.add(base)

    matched = [name for name in sorted(candidates) if name and git_grep_files(name)]
    if not matched:
        searched = ",".join(sorted(candidates)) or "-"
        fail(
            2,
            f"NO_IMAGE repo={repo} searched={searched}\n"
            "HINT: pass --image <name> when the image name is not discoverable "
            "from the app workflow.",
        )
    return matched


def registry_token(repo_path):
    scope = urllib.parse.quote(f"repository:{repo_path}:pull", safe=":/")
    url = f"https://ghcr.io/token?scope={scope}"
    headers = {"User-Agent": "infra-pin-app-image"}
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response).get("token", "")
    except urllib.error.HTTPError as exc:
        if exc.code not in (401, 403) or not token:
            raise
    # Private package fallback: try the GitHub token as a bearer/basic credential.
    for auth in (f"Bearer {token}", "Basic " + base64.b64encode(f"{owner}:{token}".encode()).decode()):
        request = urllib.request.Request(url, headers={**headers, "Authorization": auth})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response).get("token", "")
        except urllib.error.HTTPError:
            continue
    return ""


def manifest_digest(repo_path, ref, attempt=1):
    try:
        auth = registry_token(repo_path)
        headers = {
            "Accept": manifest_accept,
            "User-Agent": "infra-pin-app-image",
        }
        if auth:
            headers["Authorization"] = f"Bearer {auth}"
        url = (
            f"https://ghcr.io/v2/{repo_path}/manifests/"
            f"{urllib.parse.quote(ref, safe='')}"
        )
        request = urllib.request.Request(url, headers=headers, method="HEAD")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                value = response.headers.get("docker-content-digest") or response.headers.get(
                    "Docker-Content-Digest"
                )
                if value:
                    return value.strip()
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            if exc.code == 405:
                request = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(request, timeout=30) as response:
                    value = response.headers.get(
                        "docker-content-digest"
                    ) or response.headers.get("Docker-Content-Digest")
                    return value.strip() if value else None
            if exc.code in (403, 429) and attempt < 4:
                time.sleep(5 * attempt)
                return manifest_digest(repo_path, ref, attempt + 1)
            raise
    except Exception:
        if attempt >= 3:
            raise
        time.sleep(2)
        return manifest_digest(repo_path, ref, attempt + 1)
    return None


def digest_for_sha(repo_path):
    tried = []
    for ref in (f"sha-{sha}", f"sha-{sha[:12]}", f"sha-{sha[:7]}"):
        if ref in tried:
            continue
        tried.append(ref)
        value = manifest_digest(repo_path, ref)
        if value:
            return ref, value
    fail(
        3,
        f"DIGEST_NOT_FOUND repo={repo} image={repo_path} tried={','.join(tried)}",
    )


def wait_promoted(repo_path, expected):
    deadline = time.time() + timeout
    last = None
    while True:
        current = manifest_digest(repo_path, tag)
        last = current
        if current == expected:
            return True
        if time.time() >= deadline:
            return False
        print(
            f"WAITING_PROMOTION image={repo_path} tag={tag} "
            f"expected={expected} current={current or 'missing'}",
            flush=True,
        )
        time.sleep(poll)


def update_files(image, new_digest):
    files = git_grep_files(image)
    changed = []
    seen = 0
    if not files:
        return changed, seen
    ref_re = re.compile(
        rf"(ghcr\.io/{re.escape(owner)}/{re.escape(image)}:{re.escape(tag)})"
        r"@sha256:[0-9a-f]{64}"
    )
    old_re = re.compile(
        rf"ghcr\.io/{re.escape(owner)}/{re.escape(image)}:{re.escape(tag)}"
        r"@(sha256:[0-9a-f]{64})"
    )
    for relative in files:
        path = os.path.join(root, relative)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            continue
        olds = sorted(set(old_re.findall(text)))
        new_text, count = ref_re.subn(rf"\1@{new_digest}", text)
        if count == 0:
            continue
        seen += count
        if new_text == text:
            print(
                f"ALREADY_PINNED file={relative} image={image} digest={new_digest}",
                flush=True,
            )
            continue
        if not dry_run:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(new_text)
        for old in olds:
            print(
                f"UPDATED file={relative} image={image} replacements={count} "
                f"old={old} new={new_digest}",
                flush=True,
            )
        changed.append(relative)
    return changed, seen


images = resolve_images()
repo_paths = [f"{owner}/{name}" for name in images]
for image, repo_path in zip(images, repo_paths):
    print(f"APP repo={repo} image=ghcr.io/{repo_path} tag={tag}", flush=True)

if digest_override:
    if not digest_override.startswith("sha256:"):
        digest_override = f"sha256:{digest_override}"
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest_override):
        fail(1, f"ERROR invalid --digest: {digest_override}")

changed_files = []
seen_refs = 0
pinned_images = []
for image, repo_path in zip(images, repo_paths):
    if digest_override:
        expected = digest_override
        source = "digest"
    else:
        source, expected = digest_for_sha(repo_path)
    if verify_latest and not wait_promoted(repo_path, expected):
        fail(
            3,
            f"NOT_PROMOTED repo={repo} image={repo_path} tag={tag} "
            f"expected={expected} current={manifest_digest(repo_path, tag) or 'missing'}",
        )
    print(
        f"DIGEST image={repo_path} digest={expected} tag={tag} source={source} promoted=yes",
        flush=True,
    )
    pinned_images.append((image, expected))
    changed, seen = update_files(image, expected)
    changed_files.extend(changed)
    seen_refs += seen

# De-duplicate while preserving order (an image can be referenced in several files).
changed_files = list(dict.fromkeys(changed_files))
if not changed_files:
    if seen_refs:
        print(
            f"ALREADY_PINNED repo={repo} images={','.join(images)} tag={tag} "
            "digest already current",
            flush=True,
        )
        sys.exit(0)
    fail(
        2,
        f"NO_MATCH repo={repo} images={','.join(images)} tag={tag}\n"
        "The image may not be pinned in the Infra repo yet, or it uses a "
        "different tag. Pass --image/--tag or update the manifest first.",
    )

targets = sorted(
    {
        path.split("/")[1]
        for path in changed_files
        if path.startswith("targets/") and len(path.split("/")) > 2
    }
)
if targets:
    print(f"TARGETS {','.join(targets)}", flush=True)

if validate:
    for target in targets:
        print(f"VALIDATE target={target} files={len(changed_files)}", flush=True)
        proc = subprocess.run(["bash", "scripts/validate.sh", target], cwd=root)
        if proc.returncode != 0:
            fail(4, f"VALIDATE_FAILED target={target}")

if dry_run:
    print(f"DRY_RUN files={len(changed_files)} images={','.join(images)}", flush=True)
    sys.exit(0)

if commit:
    if not message:
        pinned = ", ".join(f"{image}@{digest}" for image, digest in pinned_images)
        message = f"chore(apps): pin {pinned}"
    subprocess.run(["git", "-C", root, "add", "--", *changed_files], check=True)
    proc = subprocess.run(
        ["git", "-C", root, "commit", "-m", message, "--", *changed_files],
        text=True,
    )
    if proc.returncode != 0:
        fail(1, "ERROR git commit failed")
    short = subprocess.run(
        ["git", "-C", root, "rev-parse", "--short", "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    print(f"COMMITTED {short} files={len(changed_files)}", flush=True)
else:
    print(f"WORKTREE_UPDATED files={len(changed_files)}", flush=True)
PY
