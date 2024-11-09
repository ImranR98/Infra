#!/bin/bash
set -e

HERE_M3U8="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd;)"
source "$HERE_M3U8"/prep_env.sh

printTitle "Install Docker"
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
echo "Done."

printTitle "Prepare FRPS dependencies"
syncRemoteEnvFileIfUndefined "$PROXY_SSH_STRING" "$PROXY_HOME/landscape-remote-services/state/frps-tokens.txt" "$MAIN_NODE_HOSTNAME_LOWERCASE" "$(echo $RANDOM | sha512sum | awk '{print $1}')$(echo $RANDOM | sha512sum | awk '{print $1}')" "$HERE_M3U8"/files/frps-tokens.txt
scp -q "$HERE_M3U8"/files/frps-tokens.txt "$PROXY_SSH_STRING":~/landscape-remote-services/state/frps-tokens.txt
scp -q "$HERE_M3U8"/files/openTCPPort.sh "$PROXY_SSH_STRING":~/landscape-remote-services/openTCPPort.sh
rm "$HERE_M3U8"/files/frps-tokens.txt
scp "$HERE_M3U8"/files/frps.create-image.sh "$PROXY_SSH_STRING":~/landscape-remote-services/frps.create-image.sh
ssh -A -t "$PROXY_SSH_STRING" "bash '$PROXY_HOME/landscape-remote-services/frps.create-image.sh'"
echo "Done."

printTitle "Prepare strelaysrv dependencies"
scp "$HERE_M3U8"/files/strelaysrv.create-image.sh "$PROXY_SSH_STRING":~/landscape-remote-services/strelaysrv.create-image.sh
ssh -A -t "$PROXY_SSH_STRING" "bash '$PROXY_HOME/landscape-remote-services/strelaysrv.create-image.sh'"
echo "Done."

printTitle "Prepare Logtfy dependencies"
cat "$HERE_M3U8"/files/logtfy.json | envsubst >"$HERE_M3U8"/files/logtfy.remote.temp.json
jq '.moduleCustomization |= map(select(.module == "ssh_logins" or .module == "port_checker"))
    | .moduleCustomization[] |= if .module == "ssh_logins" then . + {loggerArg: "ssh"} 
    else . + {loggerArg: "localhost 8888", enabled: true} end' "$HERE_M3U8"/files/logtfy.remote.temp.json | jq '.ntfyConfig.defaultConfig as $default | .ntfyConfig.fallbackConfig as $fallback | .ntfyConfig.defaultConfig = $fallback | .ntfyConfig.fallbackConfig = $default' >"$HERE_M3U8"/files/logtfy.remote.json
scp -q "$HERE_M3U8"/files/logtfy.remote.json "$PROXY_SSH_STRING":~/landscape-remote-services/state/logtfy.json
rm "$HERE_M3U8"/files/logtfy.remote.json
rm "$HERE_M3U8"/files/logtfy.remote.temp.json
echo "Done."

printTitle "Generate Docker Compose and Systemd Files and Start the Service"
generateComposeService landscape-remote 1000 > "$HERE_M3U8"/files/landscape-remote.service
cat "$HERE_M3U8"/landscape-remote.docker-compose.yaml | envsubst > "$HERE_M3U8"/files/landscape-remote.docker-compose.yaml
scp "$HERE_M3U8"/files/landscape-remote.install.sh "$PROXY_SSH_STRING":~/landscape-remote-services/landscape-remote.install.sh
scp "$HERE_M3U8"/files/landscape-remote.service "$PROXY_SSH_STRING":~/landscape-remote-services/state/landscape-remote.service
scp "$HERE_M3U8"/files/landscape-remote.docker-compose.yaml "$PROXY_SSH_STRING":~/landscape-remote-services/state/landscape-remote.docker-compose.yaml
rm "$HERE_M3U8"/files/landscape-remote.docker-compose.yaml
rm "$HERE_M3U8"/files/landscape-remote.service
ssh -A -t "$PROXY_SSH_STRING" "bash '$PROXY_HOME/landscape-remote-services/landscape-remote.install.sh'"
echo "Done."

printTitle "Install FRPC-Preboot"
bash "$HERE_M3U8"/files/dracut-crypt-ssh.install.sh
bash "$HERE_M3U8"/files/frpc-preboot.install.sh
rm "$HERE_M3U8"/files/frpc-preboot.ini