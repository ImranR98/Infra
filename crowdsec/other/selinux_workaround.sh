#!/bin/bash
set -e

# https://github.com/crowdsecurity/helm-charts/issues/190

# Define the policy file and module names
POLICY_FILE="/tmp/allow_logreader_to_watch_logs.te"
MODULE_FILE="/tmp/allow_logreader_to_watch_logs.mod"
PACKAGE_FILE="/tmp/allow_logreader_to_watch_logs.pp"

cat <<EOF >$POLICY_FILE # Create the policy file
module allow_logreader_to_watch_logs 1.0;

require {
    class file { watch watch_reads };
    class dir { watch };
    type container_logreader_t;
    type container_log_t;
};

allow container_logreader_t container_log_t:file { watch watch_reads };
allow container_logreader_t container_log_t:dir { watch };
EOF
checkmodule -M -m -o "$MODULE_FILE" "$POLICY_FILE" # Compile the policy file into a module
semodule_package -m $MODULE_FILE -o $PACKAGE_FILE  # Package the module into a policy package
sudo semodule -i $PACKAGE_FILE                     # Install the policy package into SELinux

# Clean up
rm -f $POLICY_FILE $MODULE_FILE $PACKAGE_FILE

# Apply the required label to the deployment
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
