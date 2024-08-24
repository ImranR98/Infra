#!/bin/bash

# Ensure K8s and Helm are already set up
# Then run these in order

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CURRENT_DIR="$(pwd)"
trap "cd "$CURRENT_DIR"" EXIT

installFRPC() {
    awk -v here="$HERE" '{gsub("path_to_here", here); print}' "$HERE"/docker-compose/frpc.service | sudo tee /etc/systemd/system/frpc.service
    sudo systemctl enable --now frpc.service
}

prepK8s() {
    kubectl create namespace production
    kubectl label nodes "$(hostname | tr "[:upper:]" "[:lower:]")" main-storage=true # Assume the control plane node is also the main-storage node
    mkdir -p "$HERE"/state
    kubectl apply -f "$HERE"/state-nfs.yaml
}

installTraefik() {
    helm repo add traefik https://helm.traefik.io/traefik
    helm repo update
    helm install --namespace production traefik traefik/traefik --values "$HERE"/traefik/values.yaml
    kubectl apply -f "$HERE"/traefik/middlewares.yaml
    kubectl apply -f "$HERE"/traefik/dashboard/ingress.yaml
}

installCrowdsec() {
    helm repo add crowdsec https://crowdsecurity.github.io/helm-charts
    helm repo update
    mkdir -p "$HERE"/state/crowdsec/db
    mkdir -p "$HERE"/state/crowdsec/dashboard-data
    mkdir -p "$HERE"/state/crowdsec/dashboard-db
    DB_EXISTS="$(ls "$HERE"/state/crowdsec/dashboard-db)"
    kubectl apply -f "$HERE"/crowdsec/db.yaml
    helm install --namespace production crowdsec crowdsec/crowdsec --values "$HERE"/crowdsec/values.yaml
    kubectl apply -f "$HERE"/crowdsec/ingress.yaml
    # if [ -z "$DB_EXISTS" ]; then # Bootstrap dashboard DB from https://crowdsec-statics-assets.s3-eu-west-1.amazonaws.com/metabase_sqlite.zip
    #     sleep 20
    #     TEMP_DIR="$(mktemp -d)"
    #     cd "$TEMP_DIR"

    #     wget https://crowdsec-statics-assets.s3-eu-west-1.amazonaws.com/metabase_sqlite.zip
    #     unzip metabase_sqlite.zip
    #     wget https://downloads.metabase.com/v0.50.21/metabase.jar
    #     wget https://repo1.maven.org/maven2/com/h2database/h2/1.4.200/h2-1.4.200.jar
    #     wget https://repo1.maven.org/maven2/com/h2database/h2/2.3.232/h2-2.3.232.jar
    #     sudo dnf install java-21-openjdk-headless

    #     java -cp h2-1.4.200.jar org.h2.tools.Script -url jdbc:h2:$TEMP_DIR/metabase.db/metabase.db.mv.db -script backup.zip -options compression zip
    #     java -cp h2-2.3.232.jar org.h2.tools.RunScript -url jdbc:h2:$TEMP_DIR/newdb.db -script backup.zip -options compression zip FROM_1X

    #     awk 'NR==1,/ClusterIP/{sub(/ClusterIP/, "NodePort")} 1' "$HERE"/crowdsec/dashboard.yaml >temp.yaml
    #     sleep 10
    #     kubectl apply -f temp.yaml
    #     sleep 10
    #     DB_PORT="$(kubectl -n production get svc crowdsec-dashboard-db -o jsonpath='{.spec.ports[0].nodePort}')"
    #     DB_NAME="$(cat "$HERE"/crowdsec/dashboard.yaml | grep POSTGRES_DB | awk -F: '{print $NF}' | xargs)"
    #     DB_USER="$(cat "$HERE"/crowdsec/dashboard.yaml | grep POSTGRES_USER | awk -F: '{print $NF}' | xargs)"
    #     DB_PASS="$(cat "$HERE"/crowdsec/dashboard.yaml | grep POSTGRES_PASSWORD | awk -F: '{print $NF}' | xargs)"
    #     export MB_DB_TYPE=postgres
    #     export MB_DB_CONNECTION_URI="jdbc:postgresql://localhost:$DB_PORT/$DB_NAME?user=$DB_USER&password=$DB_PASS"
    #     java -jar metabase.jar load-from-h2 "$TEMP_DIR"/newdb.db # do not include .mv.db

    #     kubectl apply -f "$HERE"/crowdsec/dashboard.yaml

    #     cd "$CURRENT_DIR"
    #     rm -r "$TEMP_DIR"
    # fi # Doesn't fucking work
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

prepForLogtfy() {
    docker pull imranrdev/logtfy
    docker run --rm imranrdev/logtfy k8s >"$HERE"/docker-compose/prepLogtfy.sh
    docker run --rm imranrdev/logtfy role >"$HERE"/docker-compose/role.yaml
    bash "$HERE"/docker-compose/prepLogtfy.sh production
    echo "KUBE_API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" >"$HERE"/docker-compose/.env
}

installDockerCompose() {
    awk -v here="$HERE/docker-compose" '{gsub("path_to_here", here); print}' "$HERE"/docker-compose/docker-compose.service | sudo tee /etc/systemd/system/docker-compose.service
    sudo systemctl enable --now docker-compose.service
}

# Useful commands:
# helm upgrade -f service/values.yaml service service/service --namespace production
# kubectl run curlpod --image=alpine --restart=Never --rm -it -- /bin/sh # Then apk add --no-cache curl
# kubectl exec -it <pod-name> --stdin --tty -- bash
