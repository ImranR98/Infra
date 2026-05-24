#!/bin/bash
# Shared helpers for K3s node management (setup.sh and join.sh).

# Download the official K3s installer and verify its SHA256 checksum.
# Sets K3S_SCRIPT to the tempfile path.  Caller must provide a trap to clean up.
download_k3s_installer() {
	K3S_SCRIPT="$(mktemp /tmp/k3s-install.XXXXXX)"
	curl -fsSL --connect-timeout 30 --max-time 120 --retry 3 https://get.k3s.io -o "$K3S_SCRIPT"

	# Verify the install script SHA256 checksum
	K3S_SCRIPT_SHA256=$(curl -fsSL --connect-timeout 10 --max-time 30 https://github.com/k3s-io/k3s/raw/main/install.sh 2>/dev/null | sha256sum | cut -d' ' -f1)
	DOWNLOADED_SHA256=$(sha256sum "$K3S_SCRIPT" | cut -d' ' -f1)
	if [ -z "$K3S_SCRIPT_SHA256" ]; then
		echo "Error: could not verify K3s install script (GitHub unreachable)." >&2
		exit 1
	elif [ "$K3S_SCRIPT_SHA256" != "$DOWNLOADED_SHA256" ]; then
		echo "Error: K3s install script checksum mismatch." >&2
		echo "  Expected: $K3S_SCRIPT_SHA256" >&2
		echo "  Got:      $DOWNLOADED_SHA256" >&2
		rm -f "$K3S_SCRIPT"
		exit 1
	fi
	chmod +x "$K3S_SCRIPT"
}

# Configure firewalld to trust K3s CNI interfaces (cni0, flannel.1).
# No-op if firewall-cmd is not available (prints a warning).
configure_firewall() {
	if ! command -v firewall-cmd >/dev/null 2>&1; then
		echo "Warning: firewall-cmd not found. Skipping firewall configuration."
		echo "If using a different firewall, ensure interfaces cni0 and flannel.1 are trusted."
	else
		firewall-cmd --permanent --zone=trusted --add-interface=cni0 2>/dev/null || true
		firewall-cmd --permanent --zone=trusted --add-interface=flannel.1 2>/dev/null || true
		firewall-cmd --reload
		echo "Firewall configured. Note: VPNs may interfere with cluster networking and should run on an upstream router."
	fi
}
