#!/bin/bash
set -e

# Set hostname
sudo hostnamectl set-hostname "$1"

# Ensure the provided SSH key is trusted + disable password-based SSH login
mkdir -p ~/.ssh
if [ -z "$(grep "$2" ~/.ssh/authorized_keys)" ]; then
    echo "$2" >~/.ssh/authorized_keys
fi
chmod 0600 ~/.ssh/* 2>/dev/null || :
chmod 0700 ~/.ssh/*.pub 2>/dev/null || :
sudo sed -i "s/#* *PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
SSH_SERVICE_NAME="$(sudo systemctl list-units | grep -E 'ssh.*\.service' | awk '{print $1}' | tail -1)"
sudo systemctl enable "$SSH_SERVICE_NAME"
sudo systemctl restart "$SSH_SERVICE_NAME"
sleep 7
sudo systemctl is-active "$SSH_SERVICE_NAME"

# Increase inotify limit (useful for Syncthing, generally good practice as the default is too low)
echo "fs.inotify.max_user_watches=1000000" | sudo tee -a /etc/sysctl.conf
echo 1000000 | sudo tee /proc/sys/fs/inotify/max_user_watches