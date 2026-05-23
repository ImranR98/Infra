"""Registry API: HTTP, skopeo, Docker Registry V2 operations."""
import functools
import json
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
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


# Set by main()
VERBOSE = False
