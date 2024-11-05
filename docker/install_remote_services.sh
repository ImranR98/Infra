#!/bin/bash
set -e

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd;)"/init_vars.sh

# Install FRPS
syncRemoteEnvFileIfUndefined "$PROXY_SSH_STRING" "$PROXY_HOME/frps/frps-tokens.txt" "$MAIN_NODE_HOSTNAME_LOWERCASE" "$(echo $RANDOM | sha512sum | awk '{print $1}')$(echo $RANDOM | sha512sum | awk '{print $1}')" "$(here)"/files/frps-tokens.txt
generateComposeService frps 1000 > "$(here)"/files/frps.service
scp "$(here)"/files/.gitignore "$PROXY_SSH_STRING":~/frps/.gitignore
scp "$(here)"/files/frps-tokens.txt "$PROXY_SSH_STRING":~/frps/frps-tokens.txt
scp "$(here)"/files/frps.docker-compose.yaml "$PROXY_SSH_STRING":~/frps/frps.docker-compose.yaml
scp "$(here)"/files/frps.service "$PROXY_SSH_STRING":~/frps/frps.service
scp "$(here)"/files/frps.install.sh "$PROXY_SSH_STRING":~/frps/install.sh
scp "$(here)"/files/openTCPPort.sh "$PROXY_SSH_STRING":~/frps/openTCPPort.sh
ssh -A -t "$PROXY_SSH_STRING" bash -l <<-EOF
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
if [ -z "\$VERSION_CODENAME" ]; then
    VERSION_CODENAME="\$(cat /etc/lsb-release | grep CODENAME | awk -F= '{print \$2}')"
fi
echo \
    "deb [arch="\$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "\$VERSION_CODENAME")" stable" |
sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker \$USER
EOF
ssh -A -t "$PROXY_SSH_STRING" "bash '$PROXY_HOME/frps/install.sh'"