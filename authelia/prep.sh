#!/bin/bash
set -e
helm repo add authelia https://charts.authelia.com
helm repo update
mkdir -p "$STATE_DIR"/authelia/session
mkdir -p "$STATE_DIR"/authelia/storage