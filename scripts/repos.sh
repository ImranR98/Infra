#!/bin/bash
# DESC: Shared repository lists for the daily Renovate routine. Sourced by
# renovate-daily.sh, wait-for-runs.sh, ci-notify.sh, and renovate.sh so the
# app set is defined exactly once.

# App/ops repos: Renovate updates them, their CI tests, and (where they carry
# images) publishes. All carry GitHub Actions; dscpln-config is validation-only.
# shellcheck disable=SC2034
APP_REPOS="ImranR98/dscpln-config,ImranR98/DSCPLN,ImranR98/PixelNtfy,ImranR98/ISBN-Lookup,ImranR98/apps.obtainium.imranr.dev,ImranR98/our-times,ImranR98/order-manager,ImranR98/Logtfy,ImranR98/moving-sale-2027,ImranR98/opencode-sandbox"

# Infra owns the nfs-server image; its deps are updated in a dedicated
# pre-infra Renovate pass so the rebuilt digest is captured the same day.
# shellcheck disable=SC2034
INFRA_REPO="ImranR98/Infra"
# shellcheck disable=SC2034
DERIVED_PATHS='["targets/srv0/k3s-base/nfs-server-src/**"]'
# shellcheck disable=SC2034
DERIVED_LABEL="derived-image"
# shellcheck disable=SC2034
DIGEST_LABEL="infra-digest-pin"
