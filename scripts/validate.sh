#!/bin/bash
# DESC: Validate one target's configuration. For targets with a
# config_template/ folder: every template file must have its filled counterpart
# in config/<target>/ (same relative path) with no leftover placeholders; the
# helm values (values.yaml) and compose env (compose.env) additionally get
# key-completeness checks against the template. Targets with a k3s chart get
# helm lint + both-scope template renders ('<no value>' rejected) plus Gateway
# certificateRef/ReferenceGrant checks; compose mounts under ../../../config/
# must exist. Variable NAMES and paths only are printed — values never reach
# stdout/stderr. Runs from any machine.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") <target>"
    echo
    echo "Checks (target-dependent):"
    echo "  - every file in targets/<target>/config_template/ exists in config/<target>/"
    echo "    (same relative path) and contains no template placeholders"
    echo "  - values.yaml: key completeness vs the template (missing and extra keys)"
    echo "    and placeholder values"
    echo "  - compose.env: key completeness vs the template (missing and extra keys)"
    echo "    and placeholder values"
    echo "  - helm lint + helm template of each k3s chart (targets/<target>/k3s-base,"
    echo "    k3s-apps), rejecting '<no value>' renders"
    echo "  - every HelmChart repo is in the approved project-maintained allowlist"
    echo "  - local Traefik plugin copies under files/ match their plugins/ sources"
    echo "  - Gateway certificateRefs resolve to rendered Certificates (the two"
    echo "    shared edge Certificates) and cross-namespace refs are covered by a"
    echo "    ReferenceGrant"
    echo "  - compose mounts under ../../../config/ point at existing files"
    exit 1
}

_err() { echo "validate: $*" >&2; }

# check_yaml_vars <template> <config> — VARS completeness + placeholders, key names only.
check_yaml_vars() {
    local template="$1" config_file="$2"
    local ok=1

    local missing extra
    missing=$(comm -23 \
        <(yq '. | keys | .[]' "$template" | sort) \
        <(yq '. | keys | .[]' "$config_file" | sort))
    if [ -n "$missing" ]; then
        _err "ERROR: $config_file is missing required variables:"
        awk '{print "  " $0}' <<<"$missing" >&2
        ok=0
    fi

    extra=$(comm -13 \
        <(yq '. | keys | .[]' "$template" | sort) \
        <(yq '. | keys | .[]' "$config_file" | sort))
    if [ -n "$extra" ]; then
        _err "ERROR: $config_file has variables absent from the template (dead or renamed):"
        awk '{print "  " $0}' <<<"$extra" >&2
        ok=0
    fi

    local placeholders
    placeholders=$(yq \
        'to_entries[] | select((.value | type) == "!!str") |
         select((.value | trim) == "change_me" or (.value | trim) == "changeme" or
                (.value | trim) == "abc" or (.value | trim) == "REPLACE_ME" or
                (.value | trim | test("^<.*>$"))) | .key' \
        "$config_file")
    if [ -n "$placeholders" ]; then
        _err "ERROR: $config_file: these variables have placeholder values:"
        awk '{print "  " $0}' <<<"$placeholders" >&2
        ok=0
    fi

    # Nested/block-scalar placeholders (JWKS PEM, Authelia users DB, mosquitto
    # credentials, ...): scan every string scalar under each key, so an
    # unfilled block scalar is caught even though its trim() is not an exact
    # placeholder match. Key names only are printed.
    local k nested=""
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        if KEY="$k" yq -e \
            '.[strenv(KEY)] | .. | select(tag == "!!str") |
             select(test("change_me|changeme|REPLACE_ME|<[A-Za-z0-9 _./-]+>|p=abc"))' \
            "$config_file" >/dev/null 2>&1; then
            nested+="$k"$'\n'
        fi
    done < <(yq '. | keys | .[]' "$config_file")
    if [ -n "$nested" ]; then
        _err "ERROR: $config_file: these variables have placeholder values:"
        awk 'NF {print "  " $0}' <<<"$nested" >&2
        ok=0
    fi
    [ "$ok" = 1 ]
}

# check_env_vars <template> <config> — dotenv completeness + placeholders, key names only.
check_env_vars() {
    local template="$1" config_file="$2"
    local ok=1

    local missing extra
    missing=$(comm -23 \
        <(grep -oE '^[A-Z_][A-Z_0-9]*=' "$template" | tr -d '=' | sort) \
        <(grep -oE '^[A-Z_][A-Z_0-9]*=' "$config_file" | tr -d '=' | sort))
    if [ -n "$missing" ]; then
        _err "ERROR: $config_file is missing required variables:"
        awk '{print "  " $0}' <<<"$missing" >&2
        ok=0
    fi

    extra=$(comm -13 \
        <(grep -oE '^[A-Z_][A-Z_0-9]*=' "$template" | tr -d '=' | sort) \
        <(grep -oE '^[A-Z_][A-Z_0-9]*=' "$config_file" | tr -d '=' | sort))
    if [ -n "$extra" ]; then
        _err "ERROR: $config_file has variables absent from the template (dead or renamed):"
        awk '{print "  " $0}' <<<"$extra" >&2
        ok=0
    fi

    local placeholders
    placeholders=$(awk -F= '
        /^[A-Z_][A-Z_0-9]*=/ {
            v = substr($0, index($0, "=") + 1)
            gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, "", v)
            sub(/[ \t]+#.*$/, "", v)
            if (v == "change_me" || v == "changeme" || v == "abc" ||
                v == "REPLACE_ME" || v ~ /^<.*>$/) print $1
        }' "$config_file")
    if [ -n "$placeholders" ]; then
        _err "ERROR: $config_file: these variables have placeholder values:"
        awk '{print "  " $0}' <<<"$placeholders" >&2
        ok=0
    fi
    [ "$ok" = 1 ]
}

# check_config_files <template_dir> <config_dir> — every template file needs a
# filled counterpart; placeholder scan for non-values/non-env files.
check_config_files() {
    local template_dir="$1" config_dir="$2"
    local ok=1

    if [ ! -d "$config_dir" ]; then
        _err "ERROR: $config_dir not found — create it from the template:"
        _err "  cp -r $template_dir $config_dir   (then fill in the real values)"
        return 1
    fi

    while IFS= read -r tfile; do
        rel="${tfile#"$template_dir"/}"
        cfile="$config_dir/$rel"
        if [ ! -f "$cfile" ]; then
            _err "ERROR: missing config file: $cfile (template: $template_dir/$rel)"
            ok=0
            continue
        fi
        case "$rel" in
            values.yaml) check_yaml_vars "$tfile" "$cfile" || ok=0 ;;
            compose.env) check_env_vars "$tfile" "$cfile" || ok=0 ;;
            *)
                if grep -qE 'change_me|changeme|REPLACE_ME|<[A-Za-z0-9 _./-]+>' "$cfile"; then
                    _err "ERROR: $cfile still contains template placeholders"
                    ok=0
                fi
                ;;
        esac
    done < <(find "$template_dir" -type f | sort)
    [ "$ok" = 1 ]
}

# check_compose_mounts <target_dir> — config/ mounts referenced by the compose
# files must point at existing files.
check_compose_mounts() {
    local target_dir="$1"
    local ok=1

    local f
    for f in "$target_dir/compose/compose.yaml" "$target_dir/compose/compose.private.yaml"; do
        [ -f "$f" ] || continue
        while read -r src; do
            [ -f "$target_dir/compose/$src" ] || {
                _err "ERROR: compose mount points at a missing file: $src"
                ok=0
            }
        done < <(sed -n 's/^[[:space:]]*-[[:space:]]*\(\.\.\/\.\.\/\.\.\/config\/[A-Za-z0-9_.\/-]*\).*/\1/p' "$f")
    done
    [ "$ok" = 1 ]
}

# check_gateway_certrefs <rendered-manifests> — every Gateway listener TLS
# certificateRef must resolve to a Certificate secret in the same namespace, and
# every cross-namespace ref must be covered by a ReferenceGrant from that
# Gateway. Key names only are printed.
check_gateway_certrefs() {
    local rendered="$1"
    local ok=1

    local certs refs missing
    certs=$(yq -N 'select(.kind == "Certificate") |
        [(.metadata.namespace // "default"), (.spec.secretName // .metadata.name)] | join("/")' \
        <<<"$rendered" | awk 'NF' | sort -u)
    # shellcheck disable=SC2016  # $gns is a yq variable, not a shell one
    refs=$(yq -N 'select(.kind == "Gateway") | .metadata.namespace as $gns |
        .spec.listeners[] | .tls.certificateRefs[]? |
        [(.namespace // $gns), .name] | join("/")' <<<"$rendered" | awk 'NF' | sort -u)
    if [ -n "$refs" ]; then
        missing=$(comm -23 <(printf '%s\n' "$refs") <(printf '%s\n' "$certs"))
        if [ -n "$missing" ]; then
            _err "ERROR: Gateway certificateRefs without a matching Certificate:"
            awk 'NF {print "  " $0}' <<<"$missing" >&2
            ok=0
        fi
    fi

    local xrefs grants ungranted
    # shellcheck disable=SC2016  # $gns is a yq variable, not a shell one
    xrefs=$(yq -N 'select(.kind == "Gateway") | .metadata.namespace as $gns |
        .spec.listeners[] | .tls.certificateRefs[]? |
        select((.namespace // $gns) != $gns) | [.namespace, $gns] | join("/")' \
        <<<"$rendered" | awk 'NF' | sort -u)
    # shellcheck disable=SC2016  # $ns is a yq variable, not a shell one
    grants=$(yq -N 'select(.kind == "ReferenceGrant") | .metadata.namespace as $ns |
        select([.spec.to[]? | select((.group // "") == "" or (.group // "") == "core") |
            select(.kind == "Secret")] | length > 0) |
        .spec.from[] | select(.group == "gateway.networking.k8s.io" and .kind == "Gateway") |
        [$ns, .namespace] | join("/")' <<<"$rendered" | awk 'NF' | sort -u)
    if [ -n "$xrefs" ]; then
        ungranted=$(comm -23 <(printf '%s\n' "$xrefs") <(printf '%s\n' "$grants"))
        if [ -n "$ungranted" ]; then
            _err "ERROR: cross-namespace Gateway certificateRefs without a ReferenceGrant (<secret-ns>/<gateway-ns>):"
            awk 'NF {print "  " $0}' <<<"$ungranted" >&2
            ok=0
        fi
    fi

    # The edge TLS inventory is exactly the two shared Certificates.
    local edge edge_missing=""
    for edge in edge-public-tls edge-private-tls; do
        grep -qx "base/$edge" <<<"$certs" || edge_missing+="$edge"$'\n'
    done
    if [ -n "$edge_missing" ]; then
        _err "ERROR: missing shared edge Certificate(s):"
        awk 'NF {print "  " $0}' <<<"$edge_missing" >&2
        ok=0
    fi

    [ "$ok" = 1 ]
}

# check_helm <target_dir> — lint + template render of each k3s chart
# (targets/<t>/k3s-base → namespace/release base, k3s-apps → apps).
# check_template_values <template> <target_dir> — every top-level config key
# must be referenced by .Values.KEY in the target charts/compose/scripts, or be
# explicitly allowlisted for manual/script-only values.
check_template_values() {
    local template="$1" target_dir="$2" ok=1 key
    local allowlist=(HA_MQTT_PASSWORD TARGET)
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        case " ${allowlist[*]} " in
            *" $key "*) continue ;;
        esac
        if ! grep -Rqs -- "\.Values\.$key\b" \
            "$target_dir/k3s-base" "$target_dir/k3s-apps" \
            "$target_dir/compose" "$INFRA_ROOT/scripts" 2>/dev/null; then
            _err "ERROR: config template key '$key' is not referenced by .Values.$key (dead or script-only?)"
            ok=0
        fi
    done < <(yq '. | keys | .[]' "$template")
    [ "$ok" = 1 ]
}

# check_rendered_paths <rendered> <config> — path values must actually drive
# the PVs they claim to control.
check_rendered_paths() {
    local rendered="$1" config_file="$2" ok=1
    local pv key want got
    while IFS='|' read -r pv key; do
        want=$(yq -r ".$key // \"\"" "$config_file")
        # Empty means "derive from MAIN_PARENT_DIR" in the chart helpers; the
        # rendered path is still checked by the template tests.
        if [ -z "$want" ] || [ "$want" = "null" ]; then
            continue
        fi
        got=$(yq -N "select(.kind == \"PersistentVolume\" and .metadata.name == \"$pv\") | .spec.local.path" <<<"$rendered" | head -1)
        if [ "$got" != "$want" ]; then
            _err "ERROR: rendered PV $pv path does not match $key"
            ok=0
        fi
    done <<'EOF'
hostpath-main-node-infra-pv|INFRA_ROOT
hostpath-main-node-media-pv|MEDIA_DIR_PATH
dscpln-config-pv|DSCPLN_CONFIG_PATH
external-exposed-node-syslog-pv|JOURNAL_DIR
EOF
    [ "$ok" = 1 ]
}

# check_san_routes <rendered> — every srv0 public route must have a SAN, and
# report public SANs with no srv0 route (vps0-owned names are acceptable but
# should be reviewed; stale names are how the old `send` false positive arose).
check_san_routes() {
    local rendered="$1" ok=1
    local cert private routes public_routes missing stale
    cert=$(yq -N 'select(.kind == "Certificate" and .metadata.name == "edge-public-tls") | .spec.dnsNames[]' <<<"$rendered" | sort -u)
    private=$(yq -N 'select(.kind == "Certificate" and .metadata.name == "edge-private-tls") | .spec.dnsNames[]' <<<"$rendered" | sort -u)
    routes=$(yq -N 'select(.kind == "HTTPRoute") | .spec.hostnames[]?' <<<"$rendered" | sort -u)
    public_routes=$(comm -23 <(printf '%s\n' "$routes") <(printf '%s\n' "$private"))
    missing=$(comm -23 <(printf '%s\n' "$public_routes") <(printf '%s\n' "$cert"))
    stale=$(comm -13 <(printf '%s\n' "$public_routes") <(printf '%s\n' "$cert"))
    if [ -n "$missing" ]; then
        _err "ERROR: public routes missing from edge-public-tls:"
        awk 'NF {print "  " $0}' <<<"$missing" >&2
        ok=0
    fi
    if [ -n "$stale" ]; then
        _err "WARNING: edge-public-tls names without an srv0 HTTPRoute (vps0-owned or stale):"
        awk 'NF {print "  " $0}' <<<"$stale" >&2
    fi
    [ "$ok" = 1 ]
}

# check_global_config — cross-file/format checks that don't render a chart.
check_global_config() {
    local ok=1 vars_file key val
    vars_file="$INFRA_ROOT/config/VARS.env"
    if [ -f "$vars_file" ]; then
        while IFS= read -r key; do
            [ -n "$key" ] || continue
            _err "WARNING: config/VARS.env has a placeholder value: $key (needed only for Renovate/CI)"
        done < <(grep -E '^[A-Z][A-Z0-9_]*=.*(change_me|REPLACE_ME|<[A-Za-z])' "$vars_file" | cut -d= -f1 | grep -v '^DOCKERHUB_')
    fi

    local srv_domain srv_email vps_base vps_cloud vps_email profiles
    srv_domain="$(config_yaml srv0 .SERVICES_DOMAIN || true)"
    srv_email="$(config_yaml srv0 .DOMAIN_OWNER_EMAIL || true)"
    vps_base="$(config_env vps0 BASE_SERVICES_DOMAIN || true)"
    vps_cloud="$(config_env vps0 CLOUD_SERVICES_DOMAIN || true)"
    vps_email="$(config_env vps0 DOMAIN_OWNER_EMAIL || true)"

    if [ -n "$srv_email" ] && [ -n "$vps_email" ] && [ "$srv_email" != "$vps_email" ]; then
        _err "ERROR: DOMAIN_OWNER_EMAIL differs between config/srv0/values.yaml and config/vps0/compose.env"
        ok=0
    fi
    if [ -n "$srv_domain" ] && [ -n "$vps_base" ] && [[ "$srv_domain" != *".$vps_base" ]]; then
        _err "WARNING: SERVICES_DOMAIN '$srv_domain' does not end in BASE_SERVICES_DOMAIN '$vps_base'"
    fi
    if [ -n "$vps_cloud" ] && [ -n "$vps_base" ] && [[ "$vps_cloud" != *".$vps_base" ]]; then
        _err "WARNING: CLOUD_SERVICES_DOMAIN '$vps_cloud' does not end in BASE_SERVICES_DOMAIN '$vps_base'"
    fi

    if [ "$TARGET" = "vps0" ]; then
        profiles="$(config_env vps0 COMPOSE_PROFILES || true)"
        case ",${profiles// /,}," in
            *,dscpln-agent,*)
                if [ ! -s "$INFRA_ROOT/config/vps0/dscpln-agent/agent.json" ]; then
                    _err "ERROR: COMPOSE_PROFILES enables dscpln-agent but config/vps0/dscpln-agent/agent.json is missing"
                    ok=0
                elif grep -q '<[A-Za-z]' "$INFRA_ROOT/config/vps0/dscpln-agent/agent.json"; then
                    _err "ERROR: config/vps0/dscpln-agent/agent.json still contains template placeholders"
                    ok=0
                fi
                ;;
        esac
    fi
    [ "$ok" = 1 ]
}

# check_agent_schema <config> — validate DSCPLN_AGENTS without rendering.
check_agent_schema() {
    local config_file="$1" ok=1 name key bad
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        for key in node stateSubdir config; do
            if ! yq -e ".DSCPLN_AGENTS[\"$name\"].$key" "$config_file" >/dev/null 2>&1; then
                _err "ERROR: DSCPLN_AGENTS.$name.$key is required"
                ok=0
            fi
        done
        if yq -e ".DSCPLN_AGENTS[\"$name\"] | has(\"configSubdir\")" "$config_file" >/dev/null 2>&1; then
            _err "ERROR: DSCPLN_AGENTS.$name.configSubdir is obsolete; use stateSubdir"
            ok=0
        fi
        bad=$(yq ".DSCPLN_AGENTS[\"$name\"].dataMounts // [] | .[] | select((has(\"name\") | not) or (has(\"subdir\") | not) or (has(\"mountPath\") | not) or has(\"readOnly\")) | .name // \"<unnamed>\"" "$config_file" 2>/dev/null || true)
        if [ -n "$bad" ]; then
            _err "ERROR: DSCPLN_AGENTS.$name.dataMounts has invalid entries (need name/subdir/mountPath; readOnly is obsolete): $bad"
            ok=0
        fi
    done < <(yq '.DSCPLN_AGENTS // {} | keys | .[]' "$config_file")
    [ "$ok" = 1 ]
}

# check_cluster_hardware <config> — warn when the active profile expects a
# device resource no Ready node advertises. Runs only where kubectl can reach
# the cluster (srv0's kubeconfig is root-only).
check_cluster_hardware() {
    local config_file="$1" profile conbee node res val check
    command -v kubectl >/dev/null 2>&1 || return 0
    kubectl get node srv0 >/dev/null 2>&1 || return 0
    profile=$(yq -r '.GPU_PROFILE // "intel"' "$config_file" 2>/dev/null || echo intel)
    conbee=$(yq -r '.HA_CONBEE // true' "$config_file" 2>/dev/null || echo true)

    local checks=()
    case "$profile" in
        intel) checks=("srv0 intel-gpu" "srv0 vaapi") ;;
        amd) checks=("srv0 amd-igpu" "srv0 vaapi") ;;
        none) checks=() ;;
        *)
            _err "WARNING: unknown GPU_PROFILE '$profile'"
            return 0
            ;;
    esac
    [ "$conbee" = "false" ] || checks+=("srv0 conbee")

    for check in "${checks[@]}"; do
        node=${check%% *}
        res=${check#* }
        val=$(kubectl get node "$node" -o json 2>/dev/null | yq -r ".status.allocatable[\"infra.local/$res\"] // \"0\"" 2>/dev/null || echo 0)
        if [ -z "$val" ] || [ "$val" = "0" ] || [ "$val" = "null" ]; then
            _err "WARNING: GPU_PROFILE=$profile expects infra.local/$res on $node, but it is not advertised"
        fi
    done
}

check_helm() {
    local target_dir="$1"
    local config_file="$INFRA_ROOT/config/$TARGET/values.yaml"
    local ok=1

    local chart_dir chart ns release vars_args out all_out=""
    for chart_dir in "$target_dir"/k3s-base "$target_dir"/k3s-apps; do
        [ -d "$chart_dir" ] || continue
        chart="$(basename "$chart_dir")"
        ns="${chart#k3s-}"
        release="$TARGET-$ns"
        vars_args=(-f "$chart_dir/values.yaml")
        [ -f "$config_file" ] && vars_args+=(-f "$config_file")

        if ! helm lint "$chart_dir" "${vars_args[@]}" >/dev/null 2>&1; then
            _err "ERROR: helm lint failed ($chart)"
            ok=0
        fi

        out=$(helm template "$release" "$chart_dir" -n "$ns" \
            "${vars_args[@]}" 2>&1) || {
            _err "ERROR: helm template ($chart) failed:"
            echo "$out" >&2
            ok=0
            continue
        }
        if grep -q '<no value>' <<<"$out"; then
            _err "ERROR: helm template ($chart) rendered missing values (<no value>)"
            ok=0
        fi
        all_out+="$out"$'\n'
    done

    check_rendered_paths "$all_out" "$config_file" || ok=0
    check_san_routes "$all_out" || ok=0
    check_gateway_certrefs "$all_out" || ok=0
    [ "$ok" = 1 ]
}

# check_chart_repos <target_dir> — only project-maintained Helm chart repos are
# allowed. Home Assistant is the single approved third-party exception (no
# official Home Assistant chart exists). Apps with version-sensitive charts
# should pin image.repository/image.tag so Renovate tracks the app image.
check_chart_repos() {
    local target_dir="$1"
    local allowed=(
        "https://charts.authelia.com"
        "https://charts.jetstack.io"
        "https://crowdsecurity.github.io/helm-charts"
        "https://falcosecurity.github.io/charts"
        "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
        "https://kubernetes-sigs.github.io/descheduler"
        "https://grafana.github.io/helm-charts"
        "https://grafana-community.github.io/helm-charts"
        "https://kubernetes-sigs.github.io/headlamp"
        "oci://ghcr.io/immich-app/immich-charts/immich"
        "oci://ghcr.io/seerr-team/seerr/seerr-chart"
        "https://helm.openwebui.com"
        "https://blog.pavelsklenar.com/home-assistant-helm-chart"
    )
    local ok=1 f repo chart a found
    for f in "$target_dir"/k3s-base/templates/*.yaml "$target_dir"/k3s-apps/templates/*.yaml; do
        [ -f "$f" ] || continue
        while IFS= read -r repo; do
            repo="${repo#"${repo%%[![:space:]]*}"}"
            repo="${repo#repo: }"
            repo="${repo%/}"
            found=0
            for a in "${allowed[@]}"; do
                [ "$repo" = "$a" ] && { found=1; break; }
            done
            if [ "$found" = 0 ]; then
                _err "ERROR: unapproved Helm chart repo in ${f#"$INFRA_ROOT"/}: $repo"
                ok=0
            fi
        done < <(grep -hE '^  repo: ' "$f" || true)
        while IFS= read -r chart; do
            chart="${chart#"${chart%%[![:space:]]*}"}"
            chart="${chart#chart: }"
            case "$chart" in
                oci://*) ;;
                *) continue ;;
            esac
            found=0
            for a in "${allowed[@]}"; do
                [ "$chart" = "$a" ] && { found=1; break; }
            done
            if [ "$found" = 0 ]; then
                _err "ERROR: unapproved Helm OCI chart in ${f#"$INFRA_ROOT"/}: $chart"
                ok=0
            fi
        done < <(grep -hE '^  chart: oci://' "$f" || true)
    done
    [ "$ok" = 1 ]
}

[ $# -ge 1 ] || usage
require_target "$1"
target_dir="$INFRA_ROOT/targets/$TARGET"
template_dir="$target_dir/config_template"
ok=1

if [ -d "$template_dir" ]; then
    check_config_files "$template_dir" "$INFRA_ROOT/config/$TARGET" || ok=0
    if [ -f "$template_dir/values.yaml" ]; then
        check_template_values "$template_dir/values.yaml" "$target_dir" || ok=0
    fi
else
    echo "validate: target '$TARGET' has no config_template (no secret variables) — nothing to check"
fi

check_global_config || ok=0

config_values="$INFRA_ROOT/config/$TARGET/values.yaml"
if [ -f "$config_values" ]; then
    check_agent_schema "$config_values" || ok=0
fi

[ -d "$target_dir/k3s-base" ] && { check_helm "$target_dir" || ok=0; check_chart_repos "$target_dir" || ok=0; }

[ -d "$target_dir/compose" ] && { check_compose_mounts "$target_dir" || ok=0; }

# vps0's Authelia config is rendered from the committed base + config rules.
# The generated file only exists on vps0, so check it there.
if [ "$TARGET" = vps0 ] && [ -d "$target_dir/compose" ] && [ "$(hostname)" = vps0 ]; then
    bash "$INFRA_ROOT/scripts/render-vps0-authelia.sh" --check || ok=0
fi

# First-boot safety: the six user-facing apps are LAN/VPN-only while this is on.
if [ -f "$config_values" ]; then
    bootstrap=$(yq '.BOOTSTRAP_PRIVATE_APPS // "false"' "$config_values" 2>/dev/null || echo "false")
    if [ "$bootstrap" = "true" ]; then
        echo "WARNING: BOOTSTRAP_PRIVATE_APPS=true — Home Assistant/Immich/Jellyfin/Linkwarden/Navidrome/Opodsync are LAN/VPN-only; set it to false after Authelia is Ready." >&2
    fi
fi

# Static node labels replace NFD; warn if the target node is missing them.
if command -v kubectl >/dev/null 2>&1 && kubectl get node "$TARGET" >/dev/null 2>&1; then
    for label in hostpath-main external-exposed; do
        value=$(kubectl get node "$TARGET" -o jsonpath="{.metadata.labels.infra\.local/$label}" 2>/dev/null || true)
        [ "$value" = "true" ] || echo "WARNING: node $TARGET is missing infra.local/$label=true" >&2
    done

    main_count=$(kubectl get nodes -l infra.local/hostpath-main=true --no-headers 2>/dev/null | wc -l)
    if [ "$main_count" -gt 1 ]; then
        echo "WARNING: $main_count nodes carry infra.local/hostpath-main=true; the static Main PVs and nfs-server expect exactly one data node." >&2
    fi

    [ -f "$config_values" ] && check_cluster_hardware "$config_values"
fi

if [ "$ok" = 1 ]; then
    echo "validate: OK ($TARGET)"
    exit 0
fi
exit 1
