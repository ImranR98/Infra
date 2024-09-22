#!/bin/bash
set -e

# Kubernetes PV on the home directory will cause permission changes, making SSH key-based login fail - we need to allow "bad" permissions
sudo sed -i "s/#* *StrictModes yes/StrictModes no/" /etc/ssh/sshd_config

# Increase inotify limit (Syncthing and Immich eat these up fast)
echo "fs.inotify.max_user_watches=1000000" | sudo tee -a /etc/sysctl.conf
echo 1000000 | sudo tee /proc/sys/fs/inotify/max_user_watches