#!/bin/bash
# DESC: Enforce the image-reference policy for the deployment manifests:
# every raw image ref has an explicit tag, exact tags carry a digest, and
# floating/channel tags are limited to the documented allowlist. Chart
# repository/tag values are out of scope (the upstream chart shape has no
# digest field; Renovate tracks those tags directly).
#
# Policy:
# - Raw `image:` and Dockerfile `FROM` refs must be `repo:tag@sha256:...`.
# - Floating tags (`latest`, `stable`, `release`, `alpine`, bare major,
#   `xpu-master`, llama.cpp channel tags) are allowed only for packages that
#   publish no immutable version tag. They still need a digest.
# - `rancher/k3s-upgrade` is tagless on purpose: the system-upgrade-controller
#   derives its tag from the Plan `version`.
# - `ghcr.io/blakeblackshear/frigate` is tag-only because it is tracked via the
#   github-releases custom manager (variant-aware); it has no docker dep to pin.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi

usage() {
    echo "Usage: $(basename "$0")"
    echo
    echo "Checks every raw image ref under targets/ and the nfs-server Dockerfile:"
    echo "  - explicit tag (except rancher/k3s-upgrade)"
    echo "  - @sha256 digest on raw refs (except the github-releases-managed frigate)"
    echo "  - no floating tags outside the channel-only allowlist"
    exit 1
}

err=0
_fail() {
    echo "image-policy: ERROR: $*" >&2
    err=1
}

# Packages that only publish channel/floating tags. They are digest-pinned and
# handled by the narrow minimumReleaseAge allowlist in renovate.json.
channel_only() {
    case "$1" in
        ghcr.io/imranr98/* | \
            lscr.io/linuxserver/* | \
            ghcr.io/reliq-hq/comfyui | \
            ghcr.io/ggml-org/llama.cpp | \
            bitnami/postgresql | \
            bitnami/redis | \
            bitnami/kubectl | \
            imranrdev/attentiongame)
            return 0
            ;;
    esac
    return 1
}

# Distro/app tags that have no exact version tag upstream. Digest-pinned.
major_tag_ok() {
    case "$1" in
        fedora | jellyfin/jellyfin)
            return 0
            ;;
    esac
    return 1
}

# Tag-only exceptions.
tagless_ok() {
    [ "$1" = "rancher/k3s-upgrade" ]
}

digest_optional() {
    [ "$1" = "ghcr.io/blakeblackshear/frigate" ]
}

is_floating() {
    local tag="$1"
    case "$tag" in
        latest | stable | release | alpine)
            return 0
            ;;
    esac
    # Bare major (`1`, `2`, `v3`, `44`).
    [[ "$tag" =~ ^v?[0-9]+$ ]] && return 0
    # Major + a distro/base suffix (`3-alpine`, `16-alpine`). Two-component
    # tags with a suffix (`16.15-alpine`) are project-specific exact releases,
    # so they are not inferred as floating here.
    [[ "$tag" =~ ^v?[0-9]+-(alpine|slim|trixie|bookworm|bullseye|debian|stable|rootless|nightly|rc[0-9]*)$ ]] && return 0
    # Minor only (`3.24`, `12.4`, `24.12`).
    [[ "$tag" =~ ^v?[0-9]+\.[0-9]+$ ]] && return 0
    # Channel names used by ComfyUI/llama.cpp.
    [[ "$tag" =~ ^(xpu-master|server|server-(rocm|intel|cuda|vulkan|musa))$ ]] && return 0
    return 1
}

check_ref() {
    local file="$1" line="$2" ref="$3"

    # Ignore templated refs and empty values.
    case "$ref" in
        '' | *'$'* | *'{{'*)
            return 0
            ;;
    esac

    local name="${ref%%@*}"
    local digest=""
    if [[ "$ref" == *"@sha256:"* ]]; then
        digest="${ref##*@}"
    fi

    local tag=""
    local last="${name##*/}"
    if [[ "$last" == *:* ]]; then
        tag="${name##*:}"
        name="${name%:*}"
    fi

    if [ -z "$tag" ]; then
        if tagless_ok "$name"; then
            return 0
        fi
        _fail "$file:$line: image ref '$ref' has no tag"
        return 0
    fi

    if is_floating "$tag"; then
        if ! channel_only "$name" && ! major_tag_ok "$name"; then
            _fail "$file:$line: floating tag '$tag' on '$name'; use an exact version tag"
        fi
        if [ -z "$digest" ]; then
            _fail "$file:$line: floating tag '$tag' on '$name' must be digest-pinned"
        fi
        return 0
    fi

    # Exact tag: raw refs must be digest-pinned.
    if [ -z "$digest" ] && ! digest_optional "$name"; then
        _fail "$file:$line: '$ref' must be digest-pinned (@sha256:...)"
    fi
}

# Raw image: refs in YAML (K3s manifests/templates and compose). Compose
# private overlays are gitignored and local-only.
while IFS= read -r hit; do
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    value="${rest#*:}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value#- }"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value#image:}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    value="${value%%[[:space:]]*}"
    check_ref "$file" "$line" "$value"
done < <(grep -rnE '^[[:space:]]*(- )?image:[[:space:]]*[^[:space:]]+' targets \
    --include='*.yaml' --include='*.yml' 2>/dev/null |
    grep -v '/compose\.private\.yaml:' || true)

# Dockerfile base images.
while IFS= read -r hit; do
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    value="${rest#*:}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value#FROM}"
    value="${value#"${value%%[![:space:]]*}"}"
    # Skip --platform=... and --from=... flags.
    while [[ "$value" == --* ]]; do
        value="${value#* }"
        value="${value#"${value%%[![:space:]]*}"}"
    done
    value="${value%%[[:space:]]*}"
    check_ref "$file" "$line" "$value"
done < <(grep -rnE '^[[:space:]]*FROM[[:space:]]+' targets \
    --include='Dockerfile' --include='*.Dockerfile' 2>/dev/null || true)

if [ "$err" -ne 0 ]; then
    echo "image-policy: FAILED" >&2
    exit 1
fi
echo "image-policy: OK"
