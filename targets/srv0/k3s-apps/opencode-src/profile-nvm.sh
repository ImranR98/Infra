# shellcheck shell=bash
# nvm and Node versions are seeded onto the PVC-backed tools volume on first
# start. nvm is a bash function, so only source it in bash shells.
export NVM_DIR="${NVM_DIR:-/home/linuxbrew/.nvm}"
if [ -n "${BASH_VERSION:-}" ] && [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
    nvm use --silent default >/dev/null 2>&1 || true
fi
