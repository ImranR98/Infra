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

    instmods iwlwifi iwlmvm mac80211 cfg80211
    inst_multiple wpa_supplicant
    for plugin in /usr/lib64/NetworkManager/*/libnm-device-plugin-wifi.so; do
        [ -f "$plugin" ] && inst "$plugin"
    done

    # Generate wpa_supplicant.conf from ALL NM connection profiles.
    # Also write a net.conf with the first profile's IP settings (used as default).
    inst_hook initqueue 10 "$moddir/network-start.sh"
    inst_hook initqueue 10 "$moddir/neednet.sh"
    mkdir -p "$initdir/etc/wpa_supplicant"

    local first_ssid="" first_psk=""
    local wpa_conf="ctrl_interface=/var/run/wpa_supplicant"$'\n'
    local first=true

    for f in /etc/NetworkManager/system-connections/*.nmconnection; do
        [ -f "$f" ] || continue
        local ssid psk
        ssid=$(grep -E "^ssid=" "$f" | cut -d= -f2-)
        psk=$(grep -E "^psk=" "$f" | cut -d= -f2-)
        if [ -n "$ssid" ] && [ -n "$psk" ]; then
            wpa_conf+="network={"$'\n'
            wpa_conf+="    ssid=\"$ssid\""$'\n'
            wpa_conf+="    psk=\"$psk\""$'\n'
            wpa_conf+="}"$'\n'
            if $first; then
                first_ssid="$ssid"; first_psk="$psk"
                first=false
            fi
        fi
    done

    if [ -n "$first_ssid" ] && [ -n "$first_psk" ]; then
        printf '%s\n' "$wpa_conf" > "$initdir/etc/wpa_supplicant/wpa_supplicant.conf"
    fi
}
DRACUT_EOF

cat > "$DRACUT_MODULE_DIR/99nm-wifi/network-start.sh" << 'DRACUT_EOF'
#!/usr/bin/sh
# Bring up networking using any available method:
# 1. Ethernet/DHCP: handled by NM daemon running in parallel
# 2. WiFi: manual wpa_supplicant (bypasses D-Bus), always DHCP
# Retries WiFi every 15s, supports all networks in wpa_supplicant.conf

MAX_WAIT=60
start=$(cat /proc/uptime | cut -d. -f1)
last_wifi_attempt=0
wifi_pid=""
wifi_iface=""
has_wifi=false

# Find the wireless interface
for iface in /sys/class/net/*; do
    [ -d "$iface" ] || continue
    name=$(basename "$iface")
    [ "$name" = "lo" ] && continue
    if [ -d "/sys/class/net/$name/wireless" ] || [ -d "/sys/class/net/$name/phy80211" ]; then
        wifi_iface="$name"
        has_wifi=true
        break
    fi
done

while true; do
    now=$(cat /proc/uptime | cut -d. -f1)
    elapsed=$(( now - start ))
    [ $elapsed -ge $MAX_WAIT ] && break

    # Check if any interface has an IP (Ethernet via NM, or our WiFi with DHCP)
    got_ip=false
    for iface in /sys/class/net/*; do
        [ -d "$iface" ] || continue
        name=$(basename "$iface")
        [ "$name" = "lo" ] && continue
        if ip -4 addr show "$name" 2>/dev/null | grep -q "inet "; then
            got_ip=true; break
        fi
    done
    if $got_ip; then
        > /tmp/net.ready
        exit 0
    fi

    # No IP yet. After 10s, try WiFi with wpa_supplicant + DHCP.
    # Retry every 15s if connection doesn't stick.
    if $has_wifi && [ -f /etc/wpa_supplicant/wpa_supplicant.conf ] && [ "$elapsed" -ge 10 ]; then
        if [ -z "$wifi_pid" ] || [ $(( elapsed - last_wifi_attempt )) -ge 15 ]; then
            [ -n "$wifi_pid" ] && kill "$wifi_pid" 2>/dev/null
            ip link set "$wifi_iface" up 2>/dev/null
            wpa_supplicant -B -i "$wifi_iface" -c /etc/wpa_supplicant/wpa_supplicant.conf
            wifi_pid=$(pgrep -f "wpa_supplicant.*$wifi_iface" | head -1)
            sleep 3
            # Always use DHCP in initramfs regardless of post-boot IP config
            dhclient -v "$wifi_iface" 2>/dev/null &
            last_wifi_attempt=$elapsed
        fi
    fi

    sleep 2
done

> /tmp/net.ready
exit 0
DRACUT_EOF

cat > "$DRACUT_MODULE_DIR/99nm-wifi/neednet.sh" << 'DRACUT_EOF'
#!/usr/bin/sh
# Signal dracut that networking is needed, even when
# the default rd.neednet/ip= chain doesn't propagate correctly.
# This tells NetworkManager's initrd hook to run.
mkdir -p /run/NetworkManager/initrd
> /run/NetworkManager/initrd/neednet
DRACUT_EOF

chmod +x "$DRACUT_MODULE_DIR/99nm-wifi/module-setup.sh" "$DRACUT_MODULE_DIR/99nm-wifi/neednet.sh" "$DRACUT_MODULE_DIR/99nm-wifi/network-start.sh"

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
