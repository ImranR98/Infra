#!/bin/bash
set -e

# Prep
ORIGINAL_DIR="$(pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
UPDATE_DIR=~/temp
mkdir -p "$UPDATE_DIR"
chown $(id -u):$(id -g) "$UPDATE_DIR"
trap "cd '$ORIGINAL_DIR'" EXIT
cd "$UPDATE_DIR"