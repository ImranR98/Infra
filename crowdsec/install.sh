#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm install --namespace production crowdsec crowdsec/crowdsec --values "$HERE"/values.yaml