#!/bin/bash
set -e
HERE_F9AC="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

USERNAME="$1"
if [ -z "$USERNAME" ]; then exit 1; fi

if ! which rpm-ostree; then
    dnf copr enable uriesk/dracut-crypt-ssh -y
    dnf install dracut-crypt-ssh -y
    sed -i 's/^\(GRUB_CMDLINE_LINUX=".*\)"/\1 rd.neednet=1 ip=dhcp"/' /etc/default/grub
    grub2-mkconfig --output /etc/grub2.cfg
else
    wget -nv https://copr.fedorainfracloud.org/coprs/uriesk/dracut-crypt-ssh/repo/fedora-42/uriesk-dracut-crypt-ssh-fedora-42.repo -O /etc/yum.repos.d/dracut-crypt-ssh.repo
    rpm-ostree initramfs --enable || :
    rpm-ostree refresh-md
    if ! rpm-ostree status | grep dracut-crypt-ssh; then
        rpm-ostree install --apply-live --assumeyes dracut-crypt-ssh
    fi
    if ! rpm-ostree kargs | grep -q neednet; then
        rpm-ostree kargs --append "rd.neednet=1 ip=dhcp"
    fi
fi

sed -i '/^#[[:space:]]*install_items/s/^#[[:space:]]*//' /etc/dracut.conf.d/crypt-ssh.conf # Ensure cryptsetup is included
sed -i 's/"222"/"22"/g' /etc/dracut.conf.d/crypt-ssh.conf                                  # Change to port 22
sed -i '/^#[[:space:]]*dropbear_port/s/^#[[:space:]]*//' /etc/dracut.conf.d/crypt-ssh.conf # Uncomment to use custom port
sed -i '/^#[[:space:]]*dropbear_acl/s/^#[[:space:]]*//' /etc/dracut.conf.d/crypt-ssh.conf  # Uncomment to use custom authorized_keys path
sed -i 's/\/root\/.ssh/\/etc\/.ssh/g' /etc/dracut.conf.d/crypt-ssh.conf
umask 0077
mkdir -p /etc/dracut-crypt-ssh-keys # Generate keys if needed
test -f /etc/dracut-crypt-ssh-keys/ssh_dracut_rsa_key || ssh-keygen -t rsa -m PEM -f /etc/dracut-crypt-ssh-keys/ssh_dracut_rsa_key -N ""
test -f /etc/dracut-crypt-ssh-keys/ssh_dracut_ecdsa_key || ssh-keygen -t ecdsa -m PEM -f /etc/dracut-crypt-ssh-keys/ssh_dracut_ecdsa_key -N ""
test -f /etc/dracut-crypt-ssh-keys/ssh_dracut_ed25519_key || ssh-keygen -t ed25519 -m PEM -f /etc/dracut-crypt-ssh-keys/ssh_dracut_ed25519_key -N ""
sed -i 's/# dropbear_ed25519_key="GENERATE"/dropbear_ed25519_key="\/etc\/dracut-crypt-ssh-keys\/ssh_dracut_ed25519_key"/g' /etc/dracut.conf.d/crypt-ssh.conf # Tell it where to find keys
sed -i 's/# dropbear_rsa_key="GENERATE"/dropbear_rsa_key="\/etc\/dracut-crypt-ssh-keys\/ssh_dracut_rsa_key"/g' /etc/dracut.conf.d/crypt-ssh.conf
sed -i 's/# dropbear_ecdsa_key="GENERATE"/dropbear_ecdsa_key="\/etc\/dracut-crypt-ssh-keys\/ssh_dracut_ecdsa_key"/g' /etc/dracut.conf.d/crypt-ssh.conf
mkdir -p /etc/.ssh
if [ -f "/home/$USERNAME/.ssh/authorized_keys" ]; then cp "/home/$USERNAME/.ssh/authorized_keys" /etc/.ssh/; fi

if ! which rpm-ostree; then
    dracut --force
fi
