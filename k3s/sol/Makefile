.NOTPARALLEL:
.PHONY: help all k3s k3s-base base apps namespaces nfs-server csi-driver-nfs longhorn validate update domains
.DEFAULT_GOAL := help

CURRENT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
COMPONENTS_DIR := $(CURRENT_DIR)/components
SCRIPTS_DIR := $(CURRENT_DIR)/scripts

# Order matters:
#   1. k3s               — install K3s (host-level, not Kustomize)
#   2. namespaces        — create namespaces before anything else
#   3. nfs-server        — NFS server for Longhorn backup target
#   4. csi-driver-nfs    — NFS CSI driver for mounting NFS shares as PVCs
#   5. longhorn          — distributed block storage for all PVCs
#   6. cert-manager      — needed for TLS certificates on ingress routes
#   7. traefik           — ingress controller, needs cert-manager for its own cert
#   8. crowdsec          — depends on traefik logs for acquisition
#   9. authelia          — SSO, depends on cert-manager and traefik for ingress
#  10. ntfy              — notification backbone, needed by crowdsec and others
BASE_TARGETS := namespaces nfs-server csi-driver-nfs longhorn cert-manager traefik crowdsec authelia ntfy
APPS_TARGETS := immich logtfy jellyfin navidrome mdscl homeassistant ollama nextcloud freshrss opodsync dscpln opencanary fmd syncthing

APPLY_MODE ?=

# Reverse a space-separated list (GNU Make compatible)
reverse = $(if $(wordlist 2,2,$(1)),$(call reverse,$(wordlist 2,$(words $(1)),$(1))) $(firstword $(1)),$(1))

help:
	@echo "K3s Sol Deployment"
	@echo ""
	@echo "Usage:"
	@echo "  make <component>                     Deploy a component"
	@echo "  make <component> APPLY_MODE=delete   Delete a component"
	@echo "  make <component> APPLY_MODE=diff     Preview changes without applying"
	@echo "  make <component> APPLY_MODE=initial  Deploy with initial mode (comments out # IGNORE INITIALLY lines)"
	@echo "  make <component> APPLY_MODE=yaml     Print processed YAML (dry-run validation included)"
	@echo ""
	@echo "Convenience targets:"
	@echo "  all          Install K3s + deploy all components (base + apps)"
	@echo "  k3s          Install/repair K3s cluster (idempotent)"
	@echo "  k3s-base     Install K3s + base infrastructure"
	@echo "  base         Deploy base infrastructure"
	@echo "  apps         Deploy all applications"
	@echo ""
	@echo "Utility targets:"
	@echo "  validate     Validate kustomization.yaml references, orphans, and env var consistency"
	@echo "  update       Update Helm chart versions and container image tags"
	@echo "  domains      List all DNS domains required by IngressRoutes"
	@echo ""
	@echo "Optional variables:"
	@echo "  APPLY_MODE=yaml      Print processed YAML to stdout (skips prep/post)"
	@echo "  APPLY_MODE=initial   Deploy with initial mode (comments out # IGNORE INITIALLY lines)"
	@echo "  APPLY_MODE=delete    Delete resources instead of applying"
	@echo "  APPLY_MODE=diff      Preview changes with kubectl diff"

# Host-level: install/repair K3s cluster
k3s:
	@if [ "$(APPLY_MODE)" = "delete" ]; then echo "Error: Cannot delete k3s via Makefile."; exit 1; fi
	@if ! command -v kubectl >/dev/null 2>&1 || ! kubectl cluster-info >/dev/null 2>&1; then \
		SU=$$(if command -v run0 >/dev/null 2>&1; then echo run0; else echo sudo; fi); \
		$$SU bash -c 'cd $(COMPONENTS_DIR)/k3s && ./k3s.sh' && $$SU bash -c 'cd $(COMPONENTS_DIR)/k3s && ./firewall.sh'; \
	fi

# Generic K8s component deployment
define deploy-component
  $(SCRIPTS_DIR)/apply.sh $1 "$(APPLY_MODE)"
endef

k3s-base:
	@if [ "$(APPLY_MODE)" = "delete" ]; then echo "Error: Cannot delete k3s-base. Delete k3s and base separately."; exit 1; fi
	@$(MAKE) k3s base
base: $(if $(filter delete,$(APPLY_MODE)),$(call reverse,$(BASE_TARGETS)),$(BASE_TARGETS))
apps: $(if $(filter delete,$(APPLY_MODE)),$(call reverse,$(APPS_TARGETS)),$(APPS_TARGETS))
all:
	@if [ "$(APPLY_MODE)" = "delete" ]; then echo "Error: Cannot delete all via Makefile. Delete individual components instead."; exit 1; fi
	@$(MAKE) k3s base apps

validate:
	@bash $(SCRIPTS_DIR)/validate.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "Running shellcheck..."; \
		find $(SCRIPTS_DIR) -name '*.sh' -exec shellcheck {} + && \
		find $(COMPONENTS_DIR) -name '*.sh' -exec shellcheck {} +; \
	else \
		echo "Warning: shellcheck not found. Install it to validate shell scripts."; \
	fi

update:
	@echo "Updating Helm chart and container image versions..."
	@python3 $(SCRIPTS_DIR)/update-versions.py

domains:
	@bash -c 'ROOT_DIR='$(CURRENT_DIR)' && \
		export VARS_ROOT="$$ROOT_DIR/../.." && \
		export TARGET="$$(basename "$$ROOT_DIR")" && \
		source "$$VARS_ROOT/lib/vars.sh" && \
		source_env && \
		VARS=$$(get_envsubst_vars) && \
		grep -rohP "Host\(\x60[^\x60]+\x60\)" --include="*.yaml" $(COMPONENTS_DIR) | \
		sed "s/.*\x60\([^\x60]*\)\x60.*/\1/" | \
		grep -v "\.localhost" | \
		envsubst "$$VARS" | \
		sort -u'

# All K8s components use the generic deploy function
%:
	@if [ -z "$@" ]; then echo "Error: Empty target specified."; exit 1; fi
	@if [ ! -d "$(COMPONENTS_DIR)/$@" ]; then \
		echo "Error: Unknown target '$@'. Run 'make' to see available targets."; \
		matches=$$(ls -d "$(COMPONENTS_DIR)"/"$@"* 2>/dev/null | sed 's|.*/||' | head -5); \
		if [ -n "$$matches" ]; then \
			echo "Did you mean one of these components?"; \
			echo "$$matches" | sed 's/^/  - /'; \
		fi; \
		exit 1; \
	fi
	@$(call deploy-component,$@)
