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

# --- WiFi + NetworkManager support for initramfs ---
# Swaps the default wired-only 'network' dracut module for 'network-manager'
# which handles WiFi (WPA), Ethernet, and tries all saved NM connection profiles.

DRACUT_MODULE_DIR="/usr/lib/dracut/modules.d"
if [ ! -w "$DRACUT_MODULE_DIR" ]; then
    DRACUT_MODULE_DIR="/etc/dracut/modules.d"
fi

mkdir -p "$DRACUT_MODULE_DIR/99nm-wifi"
cat > "$DRACUT_MODULE_DIR/99nm-wifi/module-setup.sh" << 'DRACUT_EOF'
#!/usr/bin/bash
check() { return 0; }
depends() { echo network-manager; return 0; }
install() {
    inst_dir /etc/NetworkManager/system-connections
    for f in /etc/NetworkManager/system-connections/*.nmconnection; do
        [ -f "$f" ] || continue
        inst "$f"
    done

    # WiFi kernel modules + firmware
    instmods iwlwifi iwlmvm mac80211 cfg80211

    # NM WiFi device plugin
    for plugin in /usr/lib64/NetworkManager/*/libnm-device-plugin-wifi.so; do
        [ -f "$plugin" ] && inst "$plugin"
    done

    # wpa_supplicant: include the systemd unit, D-Bus service file,
    # D-Bus policy config, and binary. Patch the unit for initramfs.
    # NM's nm-initrd.service will D-Bus-activate wpa_supplicant on demand.
    inst_multiple wpa_supplicant wpa_cli
    inst /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service
    inst /usr/share/dbus-1/system.d/wpa_supplicant.conf
    [ -f /etc/wpa_supplicant/wpa_supplicant.conf ] && inst /etc/wpa_supplicant/wpa_supplicant.conf
    if [ -f "$systemdsystemunitdir/wpa_supplicant.service" ]; then
        inst "$systemdsystemunitdir/wpa_supplicant.service"
        sed -i -e \
            '/^\[Unit\]/aDefaultDependencies=no\nConflicts=shutdown.target\nBefore=shutdown.target\nAfter=dbus.service' \
            "$initdir/$systemdsystemunitdir/wpa_supplicant.service"
        mkdir -p "$initdir/etc/systemd/system/initrd.target.wants"
        ln -sf "$systemdsystemunitdir/wpa_supplicant.service" \
            "$initdir/etc/systemd/system/initrd.target.wants/wpa_supplicant.service"
    fi

    # Simple initqueue hook: signal ready when any interface has an IP
    inst_hook initqueue 10 "$moddir/neednet.sh"
}
DRACUT_EOF

cat > "$DRACUT_MODULE_DIR/99nm-wifi/neednet.sh" << 'DRACUT_EOF'
#!/usr/bin/sh
# Wait for NM (Ethernet) or NM+WiFi to get an IP, then signal frpc.
# Uses return, not exit, because dracut sources this script (. "$job")
# and exit would kill the initqueue process before frpc-start runs.
MAX_WAIT=90
start=$(cat /proc/uptime | cut -d. -f1)

while true; do
    [ -f /tmp/net.ready ] && return 0
    now=$(cat /proc/uptime | cut -d. -f1)
    elapsed=$(( now - start ))
    [ $elapsed -ge $MAX_WAIT ] && break

    for iface in /sys/class/net/*; do
        [ -d "$iface" ] || continue
        name=${iface##*/}
        [ "$name" = "lo" ] && continue
        if ip -4 addr show "$name" 2>/dev/null | grep -q "inet "; then
            > /tmp/net.ready
            return 0
        fi
    done
    sleep 2
done

> /tmp/net.ready
return 0
DRACUT_EOF

chmod +x "$DRACUT_MODULE_DIR/99nm-wifi/module-setup.sh" "$DRACUT_MODULE_DIR/99nm-wifi/neednet.sh"

cat > /etc/dracut.conf.d/network-manager.conf << 'DRACUT_EOF'
add_dracutmodules+=" network-manager "
install_items+=" /usr/lib/firmware/iwlwifi-* "
DRACUT_EOF

if ! command -v rpm-ostree >/dev/null 2>&1; then
    dracut --force
else
    # rpm-ostree: regenerate initramfs with new modules+config. The --enable
    # was already done above; this rebuilds the current deployment's initramfs.
    rpm-ostree initramfs || true
fi
