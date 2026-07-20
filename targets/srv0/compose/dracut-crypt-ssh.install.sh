#!/bin/bash
set -euo pipefail

USERNAME="$1"
if [ -z "$USERNAME" ]; then exit 1; fi

if ! command -v rpm-ostree >/dev/null 2>&1; then
    dnf copr enable uriesk/dracut-crypt-ssh -y
    dnf install dracut-crypt-ssh -y
    if ! grep -q "rd.neednet=1" /proc/cmdline 2>/dev/null; then
        grubby --update-kernel=ALL --args="rd.neednet=1 ip=dhcp" || true
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

# Configure dracut-crypt-ssh in one pass
sed -i \
    -e '/^#[[:space:]]*install_items/s/^#[[:space:]]*//' \
    -e 's/"222"/"22"/g' \
    -e '/^#[[:space:]]*dropbear_port/s/^#[[:space:]]*//' \
    -e '/^#[[:space:]]*dropbear_acl/s/^#[[:space:]]*//' \
    -e 's|/root/.ssh|/etc/.ssh|g' \
    -e 's/# dropbear_ed25519_key="GENERATE"/dropbear_ed25519_key="\/etc\/dracut-crypt-ssh-keys\/ssh_dracut_ed25519_key"/g' \
    /etc/dracut.conf.d/crypt-ssh.conf

(
    umask 0077
    mkdir -p /etc/dracut-crypt-ssh-keys
    test -f /etc/dracut-crypt-ssh-keys/ssh_dracut_ed25519_key || \
        ssh-keygen -t ed25519 -m PEM -f /etc/dracut-crypt-ssh-keys/ssh_dracut_ed25519_key -N "" || \
        { echo "Error: Failed to generate ed25519 key for dracut-crypt-ssh" >&2; exit 1; }
    mkdir -p /etc/.ssh
    if [ -f "/home/$USERNAME/.ssh/authorized_keys" ]; then
        cp "/home/$USERNAME/.ssh/authorized_keys" /etc/.ssh/
    fi
)

# Install dracut-net-wifi module (delegates rebuild to frpc-preboot step)
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
git clone --depth 1 https://github.com/ImranR98/dracut-net-wifi.git "$TMPDIR"
bash "$TMPDIR/setup.sh" --no-rebuild
rm -rf "$TMPDIR"
