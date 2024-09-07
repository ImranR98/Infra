#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo add traefik https://helm.traefik.io/traefik
helm repo update
mkdir -p "$STATE_DIR"/traefik-metrics/prometheus
mkdir -p "$STATE_DIR"/traefik-metrics/grafana/data
mkdir -p "$STATE_DIR"/traefik-metrics/grafana/provisioning
