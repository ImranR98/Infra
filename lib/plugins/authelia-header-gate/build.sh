#!/bin/bash
# Regenerate plugin.wasm (and refresh the srv0 kustomize copy).
# Requires tinygo: https://tinygo.org/getting-started/install/
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
INFRA_ROOT="${INFRA_ROOT:-$(cd "$PLUGIN_DIR/../.." >/dev/null 2>&1 && pwd)}"

cd "$PLUGIN_DIR"
tinygo build -buildmode=c-shared -o plugin.wasm -scheduler=none --no-debug -target=wasi .
cp plugin.wasm .traefik.yml "$INFRA_ROOT/targets/srv0/k3s/traefik/"
