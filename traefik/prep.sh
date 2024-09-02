#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo add traefik https://helm.traefik.io/traefik
helm repo update
mkdir -p "$HERE"/../state/traefik-metrics/prometheus
mkdir -p "$HERE"/../state/traefik-metrics/grafana/data
mkdir -p "$HERE"/../state/traefik-metrics/grafana/provisioning
