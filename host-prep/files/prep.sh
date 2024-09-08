#!/bin/bash
set -e

# Set hostname
sudo hostnamectl set-hostname "$1"

# Ensure the provided SSH key is trusted + disable password-based SSH login
mkdir -p ~/.ssh
if [ -z "$(grep "$2" ~/.ssh/authorized_keys)" ]; then
    echo "$2" >~/.ssh/authorized_keys
fi
chmod 0600 ~/.ssh/* || :
chmod 0700 ~/.ssh/*.pub || :
sudo sed -i "s/#* *PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
sudo systemctl enable sshd
sudo systemctl restart sshd
sleep 7
sudo systemctl is-active sshd
