#!/bin/bash
set -e

# Prep
ORIGINAL_DIR="$(pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
UPDATE_DIR=/update_artifacts
sudo mkdir -p "$UPDATE_DIR"
sudo chown $(id -u):$(id -g) "$UPDATE_DIR"
trap "cd '$ORIGINAL_DIR'" EXIT
cd "$UPDATE_DIR"

# Update strelaysrv
git -C strelaysrv-docker pull || git clone git@github.com:ImranR98/strelaysrv-docker.git
cd strelaysrv-docker
./build.sh
cd ..