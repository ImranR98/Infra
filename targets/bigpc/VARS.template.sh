# ====== bigpc — Desktop workstation ======
# Variables for the bigpc Compose stack. The stack also relies on a few
# injected variables (MY_UID, DOCKER_GID, USER, ...) provided by lib/common.sh.

# ====== Ollama ======
# Bearer token for the LAN-facing Ollama API gate (ollama-gate service,
# port 11435). Shared with secrets/VARS.srv0.sh — must match.
export OLLAMA_AUTH_TOKEN="change_me" # openssl rand -hex 32
