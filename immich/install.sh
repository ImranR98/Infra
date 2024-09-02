#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm install --create-namespace --namespace production immich immich/immich -f "$HERE"/values.yaml