#!/bin/bash -e
helm repo add traefik https://helm.traefik.io/traefik
helm repo update
mkdir -p "$HERE"/../state/traefik-metrics/prometheus
mkdir -p "$HERE"/../state/traefik-metrics/grafana/data
mkdir -p "$HERE"/../state/traefik-metrics/grafana/provisioning
