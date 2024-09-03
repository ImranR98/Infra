#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo add nextcloud https://nextcloud.github.io/helm/
helm repo update
mkdir -p "$HERE"/../state/nextcloud/db
mkdir -p "$HERE"/../state/nextcloud/data/root
mkdir -p "$HERE"/../state/nextcloud/data/html
mkdir -p "$HERE"/../state/nextcloud/data/data
mkdir -p "$HERE"/../state/nextcloud/data/config
mkdir -p "$HERE"/../state/nextcloud/data/custom_apps
mkdir -p "$HERE"/../state/nextcloud/data/tmp
mkdir -p "$HERE"/../state/nextcloud/data/themes
sudo chown -R root "$HERE"/../state/nextcloud/data