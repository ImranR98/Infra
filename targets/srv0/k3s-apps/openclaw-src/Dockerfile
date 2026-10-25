# Derived OpenClaw image: the stock browser image plus the GitHub CLI and the
# OpenCode client. The client is pointed at the standalone OpenCode server by
# the openclaw.yaml shim below; no second OpenCode server runs in this pod.
#
# The base is pinned by digest and tracked by Renovate's dockerfile manager.
# GH_VERSION and OPENCODE_VERSION are tracked by the regex managers in
# renovate.json. After a bump, rebuild and re-pin the derived digest with
# build.sh locally or .github/workflows/openclaw-image.yml in CI.
FROM ghcr.io/openclaw/openclaw:2026.10.7-browser@sha256:03856e24df2c8620901dc2f2100464e2e65b9074f23d501b4d16e42767bd3123

ARG GH_VERSION=2.103.2
ARG OPENCODE_VERSION=2.1.4

USER root

# GitHub CLI is a static Go binary; extract the release tarball instead of
# pulling apt metadata into the image. Used by the bundled github skill; the
# credential comes from OpenClaw's managed GitHub identity (Control UI), not
# from this image.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) gh_arch=amd64 ;; \
      arm64) gh_arch=arm64 ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.tar.gz" -o /tmp/gh.tgz; \
    tar -xzf /tmp/gh.tgz -C /tmp; \
    install -D -m 0755 "/tmp/gh_${GH_VERSION}_linux_${gh_arch}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_${gh_arch}"

# OpenCode client only. The real binary lives outside PATH so the wrapper can
# add --server for `run`; every other subcommand passes through unchanged.
# The client reads OPENCODE_PASSWORD for basic auth and OPENCODE_SERVER_URL for
# the server address (both set in openclaw.yaml).
RUN set -eux; \
    mkdir -p /usr/local/lib/opencode; \
    curl -fsSL "https://registry.npmjs.org/@opencode/cli-linux-x64-baseline/-/cli-linux-x64-baseline-${OPENCODE_VERSION}.tgz" -o /tmp/opencode.tgz; \
    tar -xzf /tmp/opencode.tgz -C /tmp; \
    install -m 0755 /tmp/package/bin/opencode /usr/local/lib/opencode/opencode; \
    rm -rf /tmp/opencode.tgz /tmp/package; \
    printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'real=/usr/local/lib/opencode/opencode' \
      'if [ "${1:-}" = "run" ]; then' \
      '  shift' \
      '  exec "$real" run --server "${OPENCODE_SERVER_URL:?OPENCODE_SERVER_URL is not set}" "$@"' \
      'fi' \
      'exec "$real" "$@"' \
      > /usr/local/bin/opencode; \
    chmod 0755 /usr/local/bin/opencode; \
    /usr/local/lib/opencode/opencode --version; \
    gh --version | head -1

USER node
