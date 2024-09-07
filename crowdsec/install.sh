#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm install --namespace production crowdsec crowdsec/crowdsec --values "$HERE"/values.yaml

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