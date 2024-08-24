#!/bin/bash

# Ensure K8s and Helm are already set up
# Ensure frpc is already set up

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

init() {
    kubectl create namespace production
    kubectl label nodes "$(hostname | tr "[:upper:]" "[:lower:]")" main-storage=true # Assume the control plane node is also the main-storage node
    mkdir -p "$HERE"/state
    kubectl apply -f "$HERE"/state-nfs.yaml
}

installCrowdsec() {
    helm repo add crowdsec https://crowdsecurity.github.io/helm-charts
    helm repo update
    mkdir -p "$HERE"/state/crowdsec/db
    kubectl apply -f "$HERE"/crowdsec/db.yaml
    helm install --namespace production crowdsec crowdsec/crowdsec --values "$HERE"/crowdsec/values.yaml
    # kubectl -n production exec -it crowdsec-lapi-<pod-id> -- cscli decisions list
}

installTraefik() {
    helm repo add traefik https://helm.traefik.io/traefik
    helm repo update
    helm install --namespace production traefik traefik/traefik --values "$HERE"/traefik/values.yaml
    kubectl apply -f "$HERE"/traefik/middlewares.yaml
    kubectl apply -f "$HERE"/traefik/dashboard/ingress.yaml
}

installAuthelia() {
    helm repo add authelia https://charts.authelia.com
    helm repo update
    kubectl create -n production secret generic authelia-users --from-file="$HERE"/authelia/users-database.yaml
    AUTHELIA_VERSION="$(curl https://charts.authelia.com/ | grep '\--version' | awk '{print $NF}')"
    mkdir -p "$HERE"/state/authelia/session
    mkdir -p "$HERE"/state/authelia/storage
    helm install authelia authelia/authelia --version "$AUTHELIA_VERSION" --values "$HERE"/authelia/values.yaml --namespace production
    kubectl apply -f "$HERE"/authelia/middleware.yaml
    kubectl apply -f "$HERE"/authelia/ingress.yaml
}

installCertManager() {
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    CERT_MANAGER_VERSION="$(curl -s https://api.github.com/repos/cert-manager/cert-manager/releases/latest | grep -oE 'tag_name": .+' | awk -F '"' '{print $3}')"
    helm install cert-manager jetstack/cert-manager --values "$HERE"/cert-manager/values.yaml --version "$CERT_MANAGER_VERSION" --set crds.enabled=true --namespace production
    kubectl apply -f "$HERE"/cert-manager/issuers/secret-cf-token.yaml
    kubectl apply -f "$HERE"/cert-manager/issuers/
    kubectl apply -f "$HERE"/cert-manager/certificates/production/
}

# helm upgrade -f service/values.yaml service service/service --namespace production