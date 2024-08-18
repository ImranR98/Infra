#!/bin/bash

# Ensure K8s and Helm are already set up
# Ensure frpc is already set up

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

init() {
    kubectl create namespace production
    kubectl label nodes "$(hostname | tr "[:upper:]" "[:lower:]")" main-storage=true # Assume the control plane node is also the main-storage node
    mkdir -p "$HERE"/state
    kubectl apply -f state-nfs.yaml
}

installTraefik() {
    helm repo add traefik https://helm.traefik.io/traefik
    helm repo update
    helm install --namespace=production traefik traefik/traefik --values=traefik/values.yaml
    kubectl apply -f traefik/dashboard/ingress.yaml
}

installAuthelia() {
    helm repo add authelia https://charts.authelia.com
    helm repo update
    kubectl create -n production secret generic authelia-users --from-file=authelia/users-database.yaml
    AUTHELIA_VERSION="$(curl https://charts.authelia.com/ | grep '\--version' | awk '{print $NF}')"
    mkdir -p "$HERE"/state/authelia/session
    mkdir -p "$HERE"/state/authelia/storage
    helm install authelia authelia/authelia --version "$AUTHELIA_VERSION" --values authelia/values.yaml --namespace production
    kubectl apply -f authelia/middleware.yaml
    kubectl apply -f authelia/ingress.yaml
}

installCertManager() {
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    CERT_MANAGER_VERSION="$(curl -s https://api.github.com/repos/cert-manager/cert-manager/releases/latest | grep -oE 'tag_name": .+' | awk -F '"' '{print $3}')"
    helm install cert-manager jetstack/cert-manager --values=cert-manager/values.yaml --version "$CERT_MANAGER_VERSION" --set crds.enabled=true --namespace=production
    kubectl apply -f cert-manager/issuers/secret-cf-token.yaml
    kubectl apply -f cert-manager/issuers/
    # kubectl apply -f cert-manager/certificates/staging/
    kubectl apply -f cert-manager/certificates/production/
}


