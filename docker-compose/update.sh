#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
grep '    image: ' "$HERE"/docker-compose.yaml | awk '{print $NF}' | while read item; do
    docker pull "$item"
done
sudo systemctl restart docker-compose.service
echo "NOTE: This script assumes all images in docker-compose.yaml are tagged with a non version-specific tag (like 'latest')."