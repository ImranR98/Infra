#!/bin/bash
set -e
HERE_F9AC="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Install dracut-crypt-ssh
sudo dnf copr enable uriesk/dracut-crypt-ssh -y
sudo dnf install dracut-crypt-ssh -y
sudo sudo sed -i 's/^\(GRUB_CMDLINE_LINUX=".*\)"/\1 rd.neednet=1 ip=dhcp"/' /etc/default/grub
sudo grub2-mkconfig --output /etc/grub2.cfg
sudo sed -i '/^#[[:space:]]*install_items/s/^#[[:space:]]*//' /etc/dracut.conf.d/crypt-ssh.conf
sudo sed -i 's/"222"/"22"/g' /etc/dracut.conf.d/crypt-ssh.conf
sudo umask 0077
sudo mkdir -p /root/dracut-crypt-ssh-keys
sudo test -f /root/dracut-crypt-ssh-keys/ssh_dracut_rsa_key || sudo ssh-keygen -t rsa -m PEM -f /root/dracut-crypt-ssh-keys/ssh_dracut_rsa_key
sudo test -f /root/dracut-crypt-ssh-keys/ssh_dracut_ecdsa_key || sudo ssh-keygen -t ecdsa -m PEM -f /root/dracut-crypt-ssh-keys/ssh_dracut_ecdsa_key
sudo test -f /root/dracut-crypt-ssh-keys/ssh_dracut_ed25519_key || sudo ssh-keygen -t ed25519 -m PEM -f /root/dracut-crypt-ssh-keys/ssh_dracut_ed25519_key
sudo sed -i 's/# dropbear_ed25519_key="GENERATE"/dropbear_ed25519_key="\/root\/dracut-crypt-ssh-keys\/ssh_dracut_ed25519_key"/g' /etc/dracut.conf.d/crypt-ssh.conf
sudo sed -i 's/# dropbear_rsa_key="GENERATE"/dropbear_rsa_key="\/root\/dracut-crypt-ssh-keys\/ssh_dracut_rsa_key"/g' /etc/dracut.conf.d/crypt-ssh.conf
sudo sed -i 's/# dropbear_ecdsa_key="GENERATE"/dropbear_ecdsa_key="\/root\/dracut-crypt-ssh-keys\/ssh_dracut_ecdsa_key"/g' /etc/dracut.conf.d/crypt-ssh.conf
if [ -f ~/.ssh/authorized_keys ]; then sudo cp ~/.ssh/authorized_keys /root/.ssh/; fi
sudo dracut --force