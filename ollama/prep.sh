#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
mkdir -p "$STATE_DIR"/ollama/ollama
mkdir -p "$STATE_DIR"/ollama/webui
