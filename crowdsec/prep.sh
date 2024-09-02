#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo add crowdsec https://crowdsecurity.github.io/helm-charts
helm repo update
mkdir -p "$HERE"/../state/crowdsec
