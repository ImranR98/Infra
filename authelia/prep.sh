#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo add authelia https://charts.authelia.com
helm repo update
mkdir -p "$HERE"/../state/authelia/session
mkdir -p "$HERE"/../state/authelia/storage