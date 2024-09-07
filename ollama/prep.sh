#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
mkdir -p "$HERE"/../state/ollama/ollama
mkdir -p "$HERE"/../state/ollama/webui
