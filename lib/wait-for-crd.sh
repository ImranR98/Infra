#!/bin/bash
# Shared CRD waiter for K3s post-apply hooks.

wait_for_crds() {
	local timeout_secs="${1:-300}"
	local max_tries=$(( timeout_secs / 5 ))
	shift

	for crd in "$@"; do
		for _ in $(seq 1 "$max_tries"); do
			kubectl wait --for condition=established "crd/$crd" --timeout=10s 2>/dev/null && break
			sleep 5
		done
	done
}
