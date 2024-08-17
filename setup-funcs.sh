#!/bin/bash

# Ensure K8s and Helm are already set up
# Ensure frpc is already set up

init() {
    kubectl create namespace production
}

installTraefik() {
    helm repo add traefik https://helm.traefik.io/traefik
    helm repo update
    helm install --namespace=production traefik traefik/traefik --values=traefik/values.yaml
    kubectl apply -f default-headers.yaml
    kubectl apply -f traefik/secret-dashboard.yaml
    kubectl apply -f traefik/middleware.yaml
    kubectl apply -f traefik/ingress.yaml
}

installCertManager() {
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    CERT_MANAGER_VERSION="$(curl -s https://api.github.com/repos/cert-manager/cert-manager/releases/latest | grep -oE 'tag_name": .+' | awk -F '"' '{print $3}')"
    helm install cert-manager jetstack/cert-manager --production cert-manager --values=cert-manager/values.yaml --version "$CERT_MANAGER_VERSION" --set crds.enabled=true
    kubectl apply -f cert-manager/issuers/secret-cf-token.yaml
    kubectl apply -f cert-manager/issuers/
    kubectl apply -f cert-manager/certificates/staging/
    kubectl apply -f cert-manager/certificates/production/
}

installAuthelia() {
    helm repo add authelia https://charts.authelia.com
    helm repo update
    kubectl create -n authelia secret generic authelia-users --from-file=authelia/users-database.yaml
    AUTHELIA_VERSION="$(curl https://charts.authelia.com/ | grep '\--version' | awk '{print $NF}')"
    helm install authelia authelia/authelia --version "$AUTHELIA_VERSION" --values authelia/values.yaml --namespace production
}
