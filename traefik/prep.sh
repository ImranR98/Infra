#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo add traefik https://helm.traefik.io/traefik
helm repo update
mkdir -p "$STATE_DIR"/prometheus-grafana/prometheus
mkdir -p "$STATE_DIR"/prometheus-grafana/grafana/data
mkdir -p "$STATE_DIR"/prometheus-grafana/grafana/provisioning
