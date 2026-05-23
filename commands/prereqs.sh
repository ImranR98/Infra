#!/bin/bash
set -euo pipefail
source "$VARS_ROOT/lib/common.sh"

SU=$(get_sudo_cmd)
PKG_MGR=$(detect_pkgmgr)

case "$PKG_MGR" in
	apt) $SU apt-get update -qq ;;
	dnf) $SU dnf check-update -q || true ;;
	rpm-ostree) $SU rpm-ostree refresh-md ;;
esac

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
	printf "Installing Docker and Docker Compose..."
	ensure_docker_repo "$SU" "$PKG_MGR"
	if [ "$PKG_MGR" = "rpm-ostree" ]; then
		$SU rpm-ostree install --apply-live --assumeyes docker-ce docker-ce-cli containerd.io docker-compose-plugin && echo " done" || { echo ""; echo "Docker install failed. Install manually: https://docs.docker.com/engine/install/" >&2; }
	else
		install_pkgs "$SU" "$PKG_MGR" docker-ce docker-ce-cli containerd.io docker-compose-plugin && echo " done" || { echo ""; echo "Docker install failed. Install manually: https://docs.docker.com/engine/install/" >&2; }
	fi
	$SU systemctl enable docker 2>/dev/null || true
	$SU systemctl start docker 2>/dev/null || true
else
	echo "Docker already installed."
fi

ALL_OK=true
for tool in yq envsubst jq curl python3 skopeo; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		printf "Installing %s..." "$tool"
		case "$tool" in
			envsubst)
				case "$PKG_MGR" in
					apt) pkg="gettext-base" ;;
					dnf|rpm-ostree) pkg="gettext" ;;
				esac
				;;
			python3)
				case "$PKG_MGR" in
					apt) pkg="python3" ;;
					dnf|rpm-ostree) pkg="python3" ;;
				esac
				;;
			*) pkg="$tool" ;;
		esac
		install_pkgs "$SU" "$PKG_MGR" "$pkg" && echo " done" || { echo " failed"; ALL_OK=false; }
	else
		echo "$tool already installed."
	fi
	if command -v "$tool" >/dev/null 2>&1; then
		echo "  [OK] $tool"
	else
		echo "  [MISSING] $tool"
		ALL_OK=false
	fi
done

if ! python3 -c "import yaml" >/dev/null 2>&1; then
	printf "Installing python3-yaml..."
	case "$PKG_MGR" in
		apt) pkg="python3-yaml" ;;
		dnf) pkg="python3-pyyaml" ;;
		rpm-ostree) pkg="python3-pyyaml" ;;
		*) pkg="" ;;
	esac
	if [ -n "$pkg" ] && install_pkgs "$SU" "$PKG_MGR" "$pkg" >/dev/null 2>&1; then
		echo " done"
	else
		echo " failed"
		ALL_OK=false
	fi
	if python3 -c "import yaml" >/dev/null 2>&1; then
		echo "  [OK] python3-yaml"
	else
		echo "  [MISSING] python3-yaml"
		ALL_OK=false
	fi
else
	echo "python3-yaml already installed."
	echo "  [OK] python3-yaml"
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
	echo "  [OK] docker"
	echo "  [OK] docker compose"
else
	echo "  [MISSING] docker or docker compose"
	ALL_OK=false
fi

if [ "$ALL_OK" = true ]; then
	echo ""
	echo "All prerequisites installed."
else
	echo ""
	echo "Some prerequisites are missing. Install them manually." >&2
	exit 1
fi
