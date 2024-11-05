#!/bin/bash
set -e

# Install Docker
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo &&
    sudo dnf -q install docker-ce docker-ce-cli containerd.io docker-compose docker-compose-plugin -y &&
    sudo systemctl enable --now -q docker && sleep 5 &&
    sudo systemctl is-active docker &&
    sudo usermod -aG docker $USER

# TODO: Eventually do this in prep.sh and run the rest in a subshell