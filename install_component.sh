#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/helpers.sh

while getopts "c" opt; do
    case $opt in
    c) SHELL_ONLY=true ;;
    \?) echo "Unrecognized parameter." >&2 && exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# Get component dir
COMPONENT_DIR="${1%/}"
COMPONENT_NAME="$(basename "$COMPONENT_DIR")"

# Constants
START_WITH_FILES=(prep.sh pv.yaml nfs.yaml db.yaml install.sh "$COMPONENT_NAME.yaml")
END_WITH_FILES=(middlewares.yaml ingress.yaml)
IGNORE_FILES=(values.yaml)

# Validate arg
if [ ! -d "$COMPONENT_DIR" ]; then
    echo "Dir not found: $COMPONENT_DIR" >&2
    exit 1
fi

# Order the files
ordered_files=()
for file in "${START_WITH_FILES[@]}"; do
    if [ -f "$COMPONENT_DIR/$file" ]; then
        ordered_files+=("$file")
    fi
done
for file in "$COMPONENT_DIR"/*.{yaml,sh}; do
    [ -e "$file" ] || continue
    basefile=$(basename "$file")
    if ! contains "$basefile" "${ordered_files[@]}" && ! contains "$basefile" "${START_WITH_FILES[@]}" && ! contains "$basefile" "${END_WITH_FILES[@]}" && ! contains "$basefile" "${IGNORE_FILES[@]}"; then
        ordered_files+=("$basefile")
    fi
done
for file in "${END_WITH_FILES[@]}"; do
    if [ -f "$COMPONENT_DIR/$file" ]; then
        ordered_files+=("$file")
    fi
done

# Process each file to install the component
for file in "${ordered_files[@]}"; do
    filepath="$COMPONENT_DIR/$file"
    extension="${file##*.}"
    if [ "$extension" != sh ] && [ "$SHELL_ONLY" = true ]; then
        continue
    fi
    if [ "$extension" = yaml ]; then
        COMMAND="kubectl apply -f "$filepath""
    elif [ "$extension" = sh ]; then
        COMMAND="bash "$filepath""
    fi
    echo "===
RUNNING COMMAND: $COMMAND
---"
    eval "$COMMAND"
    sleep 1 # Make progress easy to follow + allow time for pods to ramp up, etc.
done

# Useful commands:
# helm upgrade -f service/values.yaml service service/service --namespace production
# kubectl run curlpod --image=alpine --restart=Never --rm -it -- /bin/sh # Then apk add --no-cache curl
# kubectl exec -it <pod-name> --stdin --tty -- bash
# sudo kubeadm --cri-socket unix:///var/run/crio/crio.sock reset && sudo rm -r /etc/cni/net.d
