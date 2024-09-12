#!/bin/bash

NAMESPACE=kube-system
CONFIGMAP_NAME=kubelet-config
KEY=kubelet
NEW_VALUE="serverTLSBootstrap: true"

# Update the ConfigMap (for future Kubelets)
CURRENT_DATA=$(kubectl get configmap "$CONFIGMAP_NAME" --namespace="$NAMESPACE" -o jsonpath='{.data.'"$KEY"'}')
if echo "$CURRENT_DATA" | grep -q "$NEW_VALUE"; then
    : # Already OK
else
    UPDATED_DATA=$(echo -e "$CURRENT_DATA\n$NEW_VALUE")
    PATCH=$(jq -n --arg key "$KEY" --arg new_data "$UPDATED_DATA" '{data: {($key): $new_data}}')
    kubectl patch configmap "$CONFIGMAP_NAME" --namespace="$NAMESPACE" --type='merge' -p="$PATCH"
fi

# Update the existing Kubelet
if cat "/var/lib/kubelet/config.yaml" | grep -q "$NEW_VALUE"; then
    : # Already OK
else
    echo "serverTLSBootstrap: true" | sudo tee -a /var/lib/kubelet/config.yaml
    sudo systemctl restart kubelet
fi
