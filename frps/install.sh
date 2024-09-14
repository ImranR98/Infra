#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../helpers.sh

syncRemoteEnvFileIfUndefined "$PROXY_SSH_STRING" "$PROXY_HOME/frps/frps-tokens.txt" "$MAIN_NODE_HOSTNAME_LOWERCASE" "$(echo $RANDOM | sha512sum | awk '{print $1}')$(echo $RANDOM | sha512sum | awk '{print $1}')" "$HERE"/files/frps-tokens.txt

generateComposeService frps 1000 > "$HERE"/files/frps.service
rsync -r "$HERE"/files/ "$PROXY_SSH_STRING":~/frps/


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