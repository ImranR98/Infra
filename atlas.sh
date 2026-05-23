#!/bin/bash
set -euo pipefail

VARS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export VARS_ROOT

source "$VARS_ROOT/lib/common.sh"

export COMPOSE_STATE_DIR="$VARS_ROOT/current_target/compose_live_state"
export COMPOSE_STATE_BACKUP_DIR="$VARS_ROOT/current_target/compose_state_backups"
export LONGHORN_BACKUP_DIR="$VARS_ROOT/current_target/k3s_longhorn_backups"

case "${1:-}" in
	luna|lens|sol)
		export TARGET="$1"
		shift
		;;
	"")
		echo "Usage: $0 <target> <command>" >&2
		echo "Run '$0 <target>' to see available commands." >&2
		exit 1
		;;
	*)
		echo "Unknown target: $1" >&2
		echo "Valid targets: luna, lens, sol" >&2
		exit 1
		;;
esac

COMMAND="${1:-}"

# Source VARS file early (needed for prereqs and validation too)
vars_found=false
if [ -f "$VARS_ROOT/VARS.$TARGET.sh" ] || [ -f "$VARS_ROOT/VARS.sh" ]; then
	source_env "$TARGET"
	vars_found=true
fi
if [ "$vars_found" = true ]; then
	DOCKER_GID="$(getent group docker | cut -d: -f3)"
	if [ -z "$DOCKER_GID" ]; then echo "Error: docker group not found. Is Docker installed?" >&2; exit 1; fi
	export DOCKER_GID
	export FRPC_USER="${TARGET,,}"
elif [ -n "$COMMAND" ]; then
	case "$COMMAND" in
		compose|k3s)
			echo "No VARS.$TARGET.sh or VARS.sh found. Create VARS.$TARGET.sh with variables from vars/VARS.$TARGET.sh." >&2
			exit 1
			;;
	esac
fi

# ---- Compose sub-commands ----

generate_compose_configs() {
	local target="$1"
	echo "=== Re/generate various state files ==="

	if [ -f "$VARS_ROOT/templates/$target/authelia.config.yaml" ]; then
		if [ -f "$COMPOSE_STATE_DIR/authelia/config/configuration.yml" ]; then
			PROTECT_INIT_ROUTES=${PROTECT_INIT_ROUTES:-false}
		else
			PROTECT_INIT_ROUTES=${PROTECT_INIT_ROUTES:-true}
		fi
		echo "PROTECT_INIT_ROUTES=$PROTECT_INIT_ROUTES"
		if [ "$PROTECT_INIT_ROUTES" = true ]; then
			sed '/# IGNORE INITIALLY$/ s/^/# /' "$VARS_ROOT/templates/$target/authelia.config.yaml" | envsubst "$ENVSUBST_VARS" >"$COMPOSE_STATE_DIR/authelia/config/configuration.yml"
			echo "Note: the generated Authelia config does not include lines that end with \"# IGNORE INITIALLY\"."
		else
			envsubst "$ENVSUBST_VARS" < "$VARS_ROOT/templates/$target/authelia.config.yaml" >"$COMPOSE_STATE_DIR/authelia/config/configuration.yml"
		fi
		printf '%s\n' "$AUTHELIA_USERS_DATABASE" >"$COMPOSE_STATE_DIR/authelia/config/users_database.yml"
	fi

	if [ -f "$VARS_ROOT/templates/$target/traefik.dynamic-configuration.yaml" ]; then
		if [ ! -f "$COMPOSE_STATE_DIR/traefik/acme.json" ]; then
			echo '{}' >"$COMPOSE_STATE_DIR/traefik/acme.json"
			echo "Created an empty \"acme.json\"."
		fi
		chmod 600 "$COMPOSE_STATE_DIR/traefik/acme.json"
		envsubst "$ENVSUBST_VARS" < "$VARS_ROOT/templates/$target/traefik.dynamic-configuration.yaml" > "$COMPOSE_STATE_DIR/traefik/dynamic-configuration.yaml"
	fi

	if [ -f "$VARS_ROOT/templates/$target/plausible.clickhouse-config.xml" ]; then
		cp "$VARS_ROOT/templates/$target/plausible.clickhouse-config.xml" "$COMPOSE_STATE_DIR/plausible/config/clickhouse-config.xml"
	fi

	if [ -f "$VARS_ROOT/templates/$target/frpc.toml" ]; then
		mkdir -p "$COMPOSE_STATE_DIR/frpc"
		envsubst "$ENVSUBST_VARS" < "$VARS_ROOT/templates/$target/frpc.toml" > "$COMPOSE_STATE_DIR/frpc/frpc.toml"
		chmod 600 "$COMPOSE_STATE_DIR/frpc/frpc.toml"
	fi

	if [ -f "$VARS_ROOT/templates/$target/frps-tokens.txt" ]; then
		mkdir -p "$COMPOSE_STATE_DIR/frps"
		envsubst "$ENVSUBST_VARS" < "$VARS_ROOT/templates/$target/frps-tokens.txt" > "$COMPOSE_STATE_DIR/frps/tokens.txt"
		chmod 600 "$COMPOSE_STATE_DIR/frps/tokens.txt"
	fi

	echo "=== Generate Logtfy config ==="
	if [ -f "$VARS_ROOT/templates/$target/logtfy.config.json" ]; then
		mkdir -p "$COMPOSE_STATE_DIR/logtfy"
		envsubst "$ENVSUBST_VARS" < "$VARS_ROOT/templates/$target/logtfy.config.json" > "$COMPOSE_STATE_DIR/logtfy/config.json"
		echo "Done."
	else
		echo "No logtfy config template found. Skipping."
	fi
}

case "$COMMAND" in
	compose)
		SUB="${2:-}"
		COMPOSE_ARG="${3:-}"
		shift 2 || true
		ENVSUBST_VARS="$(get_envsubst_vars)"
		export ENVSUBST_VARS

		case "$SUB" in
			install)
				echo "=== Create Required Directories ==="
				tmpfile="$(mktemp)"
				trap 'rm -f "$tmpfile"' EXIT INT TERM
				envsubst "$ENVSUBST_VARS" < "$VARS_ROOT/compose/$TARGET.compose.yaml" > "$tmpfile"
				while IFS=: read -r host_path _; do
					name="$(basename "$host_path")"
					if [[ "$name" =~ \.[a-zA-Z0-9]{1,5}$ ]]; then
						mkdir -p "$(dirname "$host_path")"
						[ "$UID" -eq 0 ] && chown "$MY_UID:$MY_UID" "$(dirname "$host_path")" 2>/dev/null || :
					else
						mkdir -p "$host_path"
						[ "$UID" -eq 0 ] && chown "$MY_UID:$MY_UID" "$host_path" 2>/dev/null || :
					fi
				done < <(awk -v dir="$COMPOSE_STATE_DIR" 'index($0, dir"/") && /^[[:space:]]*-/ { sub(/^[[:space:]]*-[[:space:]]*"?/, ""); sub(/[":].*/, ""); print }' "$tmpfile")
				echo "Done."

				generate_compose_configs "$TARGET"

				echo "=== Generate Docker Compose file ==="
				cp "$tmpfile" "$COMPOSE_STATE_DIR/compose.yaml"
				rm -f "$tmpfile"
				echo "Done."

				echo "=== Install and start the $TARGET service ==="
				cat > "$COMPOSE_STATE_DIR/$TARGET.service" << EOF
[Unit]
Description=$TARGET start
StartLimitIntervalSec=0

[Service]
User=$UID
Type=simple
ExecStart=/usr/bin/docker compose -p $TARGET -f $COMPOSE_STATE_DIR/compose.yaml up
ExecStop=/usr/bin/docker compose -p $TARGET -f $COMPOSE_STATE_DIR/compose.yaml down
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
				SU=$(get_sudo_cmd)
				$SU bash -c "mv '$COMPOSE_STATE_DIR/$TARGET.service' /etc/systemd/system/$TARGET.service"
				command -v chcon &>/dev/null && $SU chcon -t systemd_unit_file_t /etc/systemd/system/$TARGET.service 2>/dev/null || true
				$SU systemctl daemon-reload && $SU systemctl enable $TARGET.service
				$SU systemctl stop $TARGET.service 2>/dev/null || true
				sleep 5
				$SU systemctl start $TARGET.service
				echo "Done."

				echo "=== Finished ==="
				echo "Note: Some services may need manual setup in their respective GUIs."
				echo ""
				;;

			install-preboot)
				if [ ! -f "$VARS_ROOT/templates/$TARGET/frpc-preboot.toml" ]; then
					echo "No preboot template found for target $TARGET." >&2
					exit 1
				fi

				echo "=== Generate preboot FRPC config ==="
				mkdir -p "$COMPOSE_STATE_DIR/frpc"
				envsubst "$ENVSUBST_VARS" < "$VARS_ROOT/templates/$TARGET/frpc-preboot.toml" > "$COMPOSE_STATE_DIR/frpc/frpc-preboot.toml"
				chmod 600 "$COMPOSE_STATE_DIR/frpc/frpc-preboot.toml"
				echo "Done."

				echo "=== Check if root partition is LUKS-encrypted ==="
				if bash "$VARS_ROOT/lib/compose/check_root_luks.sh"; then
					echo "LUKS detected. Installing preboot FRPC and dracut-crypt-ssh..."
					$(get_sudo_cmd) bash "$VARS_ROOT/lib/compose/dracut-crypt-ssh.install.sh" "${SUDO_USER:-$USER}"
					bash "$VARS_ROOT/lib/compose/frpc-preboot.install.sh" "$COMPOSE_STATE_DIR"
					echo ""
					echo "Preboot FRPC installed. The initramfs has been rebuilt."
					echo "On the next boot, FRPC will start before root is mounted,"
					echo "tunneling SSH to the FRPS server on port 8887."
				else
					echo "Root partition is not LUKS-encrypted. Skipping preboot setup."
					echo "If you add LUKS later, re-run this command."
				fi
				;;

			restart)
				SVC="$COMPOSE_ARG"
				if [ -n "$SVC" ]; then
					generate_compose_configs "$TARGET"
					envsubst "$ENVSUBST_VARS" < "$VARS_ROOT/compose/$TARGET.compose.yaml" > "$COMPOSE_STATE_DIR/compose.yaml"
					docker compose -p "$TARGET" -f "$COMPOSE_STATE_DIR/compose.yaml" down "$SVC" || :
					docker compose -p "$TARGET" -f "$COMPOSE_STATE_DIR/compose.yaml" up -d "$SVC"
				else
					echo "No service specified. Nothing will be restarted."
				fi
				;;

			backup-state)
				if ! command -v docker >/dev/null 2>&1; then
					echo "Docker is required for backup-state but is not installed." >&2
					exit 1
				fi
				if [ ! -d "$COMPOSE_STATE_DIR" ]; then
					echo "State directory not found: $COMPOSE_STATE_DIR" >&2
					exit 1
				fi

				TIMESTAMP=$(date +%Y%m%d_%H%M%S)
				mkdir -p "$COMPOSE_STATE_BACKUP_DIR"
				OUTPUT="$COMPOSE_STATE_BACKUP_DIR/$TARGET-backup-$TIMESTAMP.tar"

				echo "Backing up $COMPOSE_STATE_DIR..."
				(umask 0077; docker run --rm -v "$COMPOSE_STATE_DIR":/backup/state:ro \
					alpine sh -c 'apk add --no-cache tar >/dev/null 2>&1 && exec tar cf - --ignore-failed-read --warning=no-file-changed --warning=no-file-removed -C /backup state' > "$OUTPUT")
				if [ -s "$OUTPUT" ]; then
					echo "Backup created: $OUTPUT"
					BACKUP_RETENTION=${BACKUP_RETENTION:-1}
					if [ "$BACKUP_RETENTION" -gt 0 ]; then
						old_backups=()
						while IFS= read -r -d '' f; do
							old_backups+=("$f")
						done < <(find "$COMPOSE_STATE_BACKUP_DIR" -maxdepth 1 -name "$TARGET-backup-*.tar" -printf '%T@ %p\0' | sort -rnz | cut -z -d' ' -f2- | tail -n +$((BACKUP_RETENTION + 1)))
						for old in "${old_backups[@]}"; do
							rm -f "$old"
							echo "Pruned old backup: $old"
						done
					fi
				else
					echo "Backup failed" >&2
					rm -f "$OUTPUT"
					exit 1
				fi
				;;

			old-images)
				old_images
				;;

			update-socket-proxy)
				echo "=== Pull Latest 'wollomatic/socket-proxy:1' and Restart $TARGET if Needed ==="
				OLDSPHASH="$(docker images wollomatic/socket-proxy:1 --format '{{.ID}}')"
				docker pull wollomatic/socket-proxy:1
				NEWSPHASH="$(docker images wollomatic/socket-proxy:1 --format '{{.ID}}')"
				if [ "$OLDSPHASH" != "$NEWSPHASH" ]; then
					read -p "New image pulled. Press enter to restart $TARGET..." NOTHING
					$(get_sudo_cmd) systemctl restart "$TARGET"
				else
					echo "wollomatic/socket-proxy:1 is already the latest (only the :1 tag is tracked)."
				fi
				;;

			update-frp)
				frpc_compose_file="$VARS_ROOT/compose/$TARGET.compose.yaml"
				if [ ! -f "$frpc_compose_file" ]; then
					echo "No compose file found for target '$TARGET'." >&2
					exit 1
				fi
				if ! docker system info 2>/dev/null | grep -q "Username"; then
					echo "Not logged into Docker Hub. Run 'docker login' first." >&2
					exit 1
				fi
				current_ver="$(sed -n 's/.*image: fatedier\/frpc:v\([^"]*\).*/\1/p' "$frpc_compose_file")"
				if [ -z "$current_ver" ]; then
					echo "No fatedier/frpc image found in $frpc_compose_file. Nothing to update." >&2
					exit 0
				fi
				echo "Current FRPC version: v$current_ver"

				latest_tag="$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')"
				latest_ver="${latest_tag#v}"
				echo "Latest FRP version:  v$latest_ver"

				if [ "$current_ver" = "$latest_ver" ]; then
					echo "FRPC is already at the latest version."
					exit 0
				fi

				echo "Updating $TARGET.compose.yaml..."
				sed -i "s|image: fatedier/frpc:v$current_ver|image: fatedier/frpc:v$latest_ver|" "$frpc_compose_file"
				echo "Updating lens.compose.yaml..."
				sed -i "s|image: imranrdev/frps-with-multiuser:latest|image: imranrdev/frps-with-multiuser:v$latest_ver|" "$VARS_ROOT/compose/lens.compose.yaml"

				echo "=== Build frps-with-multiuser:v$latest_ver ==="
				TMPDIR="$(mktemp -d)"
				trap 'rm -rf "$TMPDIR"' EXIT INT TERM
				git clone https://github.com/ImranR98/frps-with-multiuser-docker.git "$TMPDIR"
				cd "$TMPDIR"
				docker build --no-cache . --network host -t "imranrdev/frps-with-multiuser:v$latest_ver"
				docker push "imranrdev/frps-with-multiuser:v$latest_ver"
				echo "=== Done ==="

				echo ""
				echo "FRPC updated from v$current_ver to v$latest_ver."
				echo "Compose files updated and image pushed to Docker Hub."
				echo ""
				echo "Next steps:"
				echo "  1. Commit and push the changes."
				echo "  2. On lens, pull the repo and restart the frps-with-multiuser container."
				echo "  3. On sol, restart the frpc container."
				echo ""
				;;

			*)
				echo "Unknown compose command: $SUB" >&2
				echo "Available: install, install-preboot, restart <svc>, backup-state, old-images, update-socket-proxy, update-frp" >&2
				exit 1
				;;
		esac
		;;

	# ---- K3s sub-commands ----

	k3s)
		SUB="${2:-}"
		APPLY_MODE="${3:-apply}"
		shift 2 || true

		case "$SUB" in
			install)
				$(get_sudo_cmd) bash "$VARS_ROOT/lib/k3s/install.sh"
				;;

			update)
				python3 "$VARS_ROOT/lib/k3s/update-versions.py"
				;;

			"")
				echo "Usage: $0 $TARGET k3s <command>" >&2
				echo "Commands:" >&2
			echo "  install                     Install/repair K3s cluster" >&2
			echo "  update                      Update Helm chart versions and image tags" >&2
				echo "  <component> [apply|initial|delete|diff|yaml]   Manage a component" >&2
				exit 1
				;;

			*)
				# Component name with optional mode
				COMPONENT="$SUB"
				bash "$VARS_ROOT/lib/k3s/apply.sh" "$COMPONENT" "$APPLY_MODE"
				;;
		esac
		;;

	# ---- Top-level commands ----

	prereqs)
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
		;;

	list-domains)
		list_domains "$TARGET"
		;;

	validate)
		validate "$TARGET"
		;;

	update-traefik-plugins)
		update_traefik_plugins "$TARGET"
		;;

	"")
		echo "Usage: $0 <target> <command>"
		echo ""
		echo "Targets:"
		echo "  luna"
		echo "  lens"
		echo "  sol"
		echo ""
		echo "Compose commands:"
		echo "  compose install            Install and start all services"
		echo "  compose install-preboot    Install preboot FRPC in initramfs"
		echo "  compose restart <svc>      Restart a single service"
		echo "  compose backup-state       Back up compose state directory"
		echo "  compose old-images         List Docker images older than 60 days"
		echo "  compose update-socket-proxy Pull latest socket-proxy and restart"
		echo "  compose update-frp         Update FRP version and push image"
		echo ""
		echo "K3s commands:"
		echo "  k3s install               Install/repair K3s cluster"
		echo "  k3s update                Update Helm chart versions and image tags"
		echo "  k3s <component> [mode]    Deploy/delete/diff a component"
		echo ""
		echo "Top-level commands:"
		echo "  prereqs                    Install prerequisites (docker, yq, envsubst, jq, curl, python3, skopeo)"
		echo "  list-domains               List all required DNS domains"
		echo "  validate                   Validate all stacks"
		echo "  update-traefik-plugins     Update Traefik plugin versions (all stacks)"
		exit 1
		;;

	*)
		echo "Unknown command: $COMMAND" >&2
		echo "Run '$0 $TARGET' to see available commands." >&2
		exit 1
		;;
esac
