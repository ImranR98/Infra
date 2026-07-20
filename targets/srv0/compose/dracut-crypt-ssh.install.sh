#!/bin/bash
set -euo pipefail

USERNAME="$1"
if [ -z "$USERNAME" ]; then exit 1; fi

if ! command -v rpm-ostree >/dev/null 2>&1; then
    dnf copr enable uriesk/dracut-crypt-ssh -y
    dnf install dracut-crypt-ssh -y
    if ! grep -q "rd.neednet=1" /etc/default/grub 2>/dev/null; then
        sed -i 's/^\(GRUB_CMDLINE_LINUX=".*\)"/\1 rd.neednet=1 ip=dhcp"/' /etc/default/grub
        grub2-mkconfig --output /etc/grub2.cfg
    fi
else
    FEDORA_VERSION=$(rpm -E %fedora)
    wget -nv "https://copr.fedorainfracloud.org/coprs/uriesk/dracut-crypt-ssh/repo/fedora-${FEDORA_VERSION}/uriesk-dracut-crypt-ssh-fedora-${FEDORA_VERSION}.repo" -O /etc/yum.repos.d/dracut-crypt-ssh.repo || true
    rpm-ostree initramfs --enable || true
    rpm-ostree refresh-md || true
    if ! rpm-ostree status | grep dracut-crypt-ssh; then
        rpm-ostree install --apply-live --assumeyes dracut-crypt-ssh || true
    fi
    if ! rpm-ostree kargs | grep -q neednet; then
        rpm-ostree kargs --append "rd.neednet=1 ip=dhcp" || true
    fi
fi

sed -i '/^#[[:space:]]*install_items/s/^#[[:space:]]*//' /etc/dracut.conf.d/crypt-ssh.conf # Ensure cryptsetup is included
sed -i 's/"222"/"22"/g' /etc/dracut.conf.d/crypt-ssh.conf                                  # Change to port 22
sed -i '/^#[[:space:]]*dropbear_port/s/^#[[:space:]]*//' /etc/dracut.conf.d/crypt-ssh.conf # Uncomment to use custom port
sed -i '/^#[[:space:]]*dropbear_acl/s/^#[[:space:]]*//' /etc/dracut.conf.d/crypt-ssh.conf  # Uncomment to use custom authorized_keys path
sed -i 's/\/root\/.ssh/\/etc\/.ssh/g' /etc/dracut.conf.d/crypt-ssh.conf
(
    umask 0077
    mkdir -p /etc/dracut-crypt-ssh-keys # Generate keys if needed
    test -f /etc/dracut-crypt-ssh-keys/ssh_dracut_rsa_key || ssh-keygen -t rsa -m PEM -f /etc/dracut-crypt-ssh-keys/ssh_dracut_rsa_key -N "" || { echo "Error: Failed to generate RSA key for dracut-crypt-ssh" >&2; exit 1; }
    test -f /etc/dracut-crypt-ssh-keys/ssh_dracut_ecdsa_key || ssh-keygen -t ecdsa -m PEM -f /etc/dracut-crypt-ssh-keys/ssh_dracut_ecdsa_key -N "" || { echo "Error: Failed to generate ECDSA key for dracut-crypt-ssh" >&2; exit 1; }
    test -f /etc/dracut-crypt-ssh-keys/ssh_dracut_ed25519_key || ssh-keygen -t ed25519 -m PEM -f /etc/dracut-crypt-ssh-keys/ssh_dracut_ed25519_key -N "" || { echo "Error: Failed to generate ed25519 key for dracut-crypt-ssh" >&2; exit 1; }
    mkdir -p /etc/.ssh
    if [ -f "/home/$USERNAME/.ssh/authorized_keys" ]; then cp "/home/$USERNAME/.ssh/authorized_keys" /etc/.ssh/; fi
)
sed -i 's/# dropbear_ed25519_key="GENERATE"/dropbear_ed25519_key="\/etc\/dracut-crypt-ssh-keys\/ssh_dracut_ed25519_key"/g' /etc/dracut.conf.d/crypt-ssh.conf # Tell it where to find keys
sed -i 's/# dropbear_rsa_key="GENERATE"/dropbear_rsa_key="\/etc\/dracut-crypt-ssh-keys\/ssh_dracut_rsa_key"/g' /etc/dracut.conf.d/crypt-ssh.conf
sed -i 's/# dropbear_ecdsa_key="GENERATE"/dropbear_ecdsa_key="\/etc\/dracut-crypt-ssh-keys\/ssh_dracut_ecdsa_key"/g' /etc/dracut.conf.d/crypt-ssh.conf

# --- Install dracut-net-wifi module (WiFi + Ethernet via NM in initramfs) ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
git clone --depth 1 https://github.com/ImranR98/dracut-net-wifi.git "$TMPDIR"
bash "$TMPDIR/setup.sh"
rm -rf "$TMPDIR"

if ! command -v rpm-ostree >/dev/null 2>&1; then
    dracut --force
else
    rpm-ostree initramfs || true
fi
