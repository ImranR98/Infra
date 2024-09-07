#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo update
helm upgrade --namespace production crowdsec crowdsec/crowdsec --values "$HERE"/values.yaml
kubectl -n production rollout restart deployment crowdsec-lapi 
kubectl -n production rollout restart daemonset crowdsec-agent

# TODO: TEMP: https://github.com/crowdsecurity/helm-charts/issues/190
kubectl patch -n production daemonset crowdsec-agent --type='strategic' -p '{
  "spec": {
    "template": {
      "spec": {
        "securityContext": {
          "seLinuxOptions": {
            "type": "container_logreader_t"
          }
        }
      }
    }
  }
}'

echo "NOTE: The Helm chart was updated, but there is no guarantee that the chart is in sync with the latest service release."