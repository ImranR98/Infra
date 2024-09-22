#!/bin/bash
set -e
helm repo add authelia https://charts.authelia.com
mkdir -p "$STATE_DIR"/authelia/session
mkdir -p "$STATE_DIR"/authelia/storage