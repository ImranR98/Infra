#!/bin/bash

# Run these functions in the order they are written

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CURRENT_DIR="$(pwd)"
trap "cd "$CURRENT_DIR"" EXIT

installK8s() {
    # Adapted from https://docs.fedoraproject.org/en-US/quick-docs/using-kubernetes/#sect-fedora40-and-newer

    # sudo kubeadm --cri-socket unix:///var/run/crio/crio.sock reset # Delete existing cluster

    NODE_TYPE="$1"
    if [ "$NODE_TYPE" != 'master' ] && [ "$NODE_TYPE" != 'worker' ]; then
        echo "Node type not specified! Must be 'master' or 'worker'." >&2
        exit 1
    fi

    # Disable swap
    sudo systemctl stop swap-create@zram0 || :
    sudo dnf remove -y zram-generator-defaults
    sudo swapoff -a

    # Add firewall exceptions
    sudo firewall-cmd --permanent --add-port=10250/tcp
    sudo firewall-cmd --permanent --add-port=10255/tcp
    sudo firewall-cmd --permanent --add-port=8472/udp
    sudo firewall-cmd --permanent --add-port=30000-32767/tcp
    sudo firewall-cmd --add-masquerade --permanent
    if [ "$NODE_TYPE" = 'master' ]; then
        sudo firewall-cmd --permanent --add-port=6443/tcp
        sudo firewall-cmd --permanent --add-port=2379-2380/tcp
        sudo firewall-cmd --permanent --add-port=10250/tcp
        sudo firewall-cmd --permanent --add-port=10251/tcp
        sudo firewall-cmd --permanent --add-port=10252/tcp
        sudo firewall-cmd --permanent --add-port=10255/tcp
        sudo firewall-cmd --permanent --add-port=8472/udp
        sudo firewall-cmd --add-masquerade --permanent
        sudo firewall-cmd --permanent --add-port=30000-32767/tcp
        sudo firewall-cmd --permanent --add-port=10250/tcp
        sudo firewall-cmd --permanent --add-port=10255/tcp
        sudo firewall-cmd --permanent --add-port=8472/udp
        sudo firewall-cmd --permanent --add-port=30000-32767/tcp
        sudo firewall-cmd --add-masquerade --permanent
        sudo firewall-cmd --permanent --zone=public --add-service=http
        sudo firewall-cmd --permanent --zone=public --add-service=https
    fi

    # More networking changes
    sudo dnf install -y iptables iproute-tc
    sudo cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    sudo modprobe overlay
    sudo modprobe br_netfilter
    sudo cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sudo sysctl --system
    sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward

    # Install and enable K8S (no harm in having kubeadm even on workers, will not be used)
    sudo dnf install -y kubernetes kubernetes-kubeadm kubernetes-client cri-o containernetworking-plugins
    sudo systemctl enable --now crio
    sudo systemctl enable --now kubelet

    # Setup the cluster
    if [ "$NODE_TYPE" = 'master' ]; then
        # Init. cluster
        sudo kubeadm --cri-socket unix:///var/run/crio/crio.sock config images pull
        sudo kubeadm --cri-socket unix:///var/run/crio/crio.sock init --pod-network-cidr=10.244.0.0/16
        # Use user-specific config, leaving original unchanged
        mkdir -p $HOME/.kube
        sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config
        # Allow the master to also be a worker
        kubectl taint nodes --all node-role.kubernetes.io/control-plane-
        # Add overlay networking (Calico)
        (cat | sudo tee /etc/NetworkManager/conf.d/calico.conf )<<-EOF
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF
        sudo systemctl restart NetworkManager
        kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/tigera-operator.yaml
        TEMP_YAML="$(mktemp)"
        wget -qO- https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/custom-resources.yaml | sed 's/192.168/10.244/g' > "$TEMP_YAML"
        kubectl apply -f "$TEMP_YAML"
        rm "$TEMP_YAML"
        kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/custom-resources.yaml
        # Check that all basic K8S components are running
        sleep 10
        kubectl get pods --all-namespaces
        sudo dnf install -y helm
    else
        echo "You still need to join the cluster manually."
    fi
}

installFRPC() {
    awk -v here="$HERE" '{gsub("path_to_here", here); print}' "$HERE"/docker-compose/frpc.service | sudo tee /etc/systemd/system/frpc.service
    sudo systemctl enable --now frpc.service
}

prepK8s() {
    kubectl create namespace production
    kubectl label nodes "$(hostname | tr "[:upper:]" "[:lower:]")" main-storage=true # Assume the control plane node is also the main-storage node
    mkdir -p "$HERE"/state
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
    kubectl apply -f "$HERE"/crowdsec/db.yaml
    kubectl apply -f "$HERE"/crowdsec/nfs.yaml
    helm install --namespace production crowdsec crowdsec/crowdsec --values "$HERE"/crowdsec/values.yaml
    kubectl apply -f "$HERE"/crowdsec/ingress.yaml
}

installAuthelia() {
    helm repo add authelia https://charts.authelia.com
    helm repo update
    kubectl create -n production secret generic authelia-users --from-file="$HERE"/authelia/users-database.yaml
    mkdir -p "$HERE"/state/authelia/session
    mkdir -p "$HERE"/state/authelia/storage
    kubectl apply -f "$HERE"/authelia/nfs.yaml
    helm install authelia authelia/authelia --values "$HERE"/authelia/values.yaml --namespace production
    kubectl apply -f "$HERE"/authelia/middleware.yaml
    kubectl apply -f "$HERE"/authelia/ingress.yaml
}

installCertManager() {
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    helm install cert-manager jetstack/cert-manager --values "$HERE"/cert-manager/values.yaml --set crds.enabled=true --namespace production
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
# sudo kubeadm --cri-socket unix:///var/run/crio/crio.sock reset && sudo rm -r /etc/cni/net.d
