# Services

My self-hosted services (in a K8s cluster that uses FRP and Traefik for Ingress).

## Prerequisites
- A Fedora server with internet access.
- A remote FRP server already set up and ready to use for public-facing access
    - This is needed because the main server is assumed to be on a network where port forwarding is not an option.
    - TODO: Automate the setup of a remote FRP server given SSH access to it.
- DNS rules already in place for the domain hardcoded in various manifest files.
- CloudFlare DNS must be used so that the HTTPS challenge passes. So the `cert-manager/issuers/secret-cf-token.yaml` file must contain a valid token.

## Usage

1. Run `generate_setup_script.sh` and run the printed commands manually, one line at a time.
    - If the K8s cluster has multiple nodes, you must join all worker nodes manually after the K8s install step (the current machine is the control plane).
2. If all goes well, periodically update the cluster services by running `generate_setup_script.sh` with the `-u` (update) parameter.

## More Details

- Most services run in a K8s cluster, with a few exceptions like FRPC and Syncthing, which run in Docker (via `docker compose`).
- Each component of the setup has its own directory.
    - A "component" is usually a service or other modular part of the infrastructure (for example the `common-pv` directory contains K8s persistent volume claims that are general and can be re-used across services).
    - Some components are completely independent and can be added/removed without affecting the rest of the system (this is usually the case for services), but others (like `traefik` or `frpc`) are not.
- The `install_component.sh` script, given a component directory, installs or updates that component using the files inside.
    - Some files have special purposes and are installed in a specific order and method as decided by the script (for example `prep.sh` or `values.yaml`).
    - All files in the component directory that do not have a special pre-defined purpose is processed in one of these ways (in alphabetical order):
        - All `sh` files are executed.
        - All `yaml` files are applied as K8s manifests.
        - All other files and subdirectories are ignored.
    - The script can be run with the `-u` option to apply updates (this changes what files are processed and how).
- The `generate_setup_script.sh` file is used to generate a set of `install_component.sh` (and other) commands in the correct order and using the correct parameters to setup or update everything.

## Migration from Docker

Some services' data can easily be migrated from an existing Docker-based (or otherwise) setup.

To do so, use the `rsyncWithChownContent` function in `helpers.sh` (since permissions between the source and destination setups may be different).

For example:

```bash
#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

mkdir -p "$HERE"/state/ntfy imranr imranr
mkdir -p "$HERE"/state/uptime imranr imranr

source "$HERE"/helpers.sh

rsyncWithChownContent ~/Main/Other/NUC-services/service-data-unsynced/HAConfig "$HERE"/state/homeassistant root 1000
rsyncWithChownContent ~/Main/Other/NUC-services/service-data-unsynced/jellyfin "$HERE"/state/jellyfin 1000 1000
rsyncWithChownContent ~/Main/Other/NUC-services/service-data-unsynced/nextcloud/html "$HERE"/state/nextcloud/data 33 1000
rsyncWithChownContent ~/Main/Other/NUC-services/service-data-unsynced/nextcloud/db "$HERE"/state/nextcloud/db 1000 1000
rsyncWithChownContent ~/Main/Other/NUC-services/service-data/ntfy/etc "$HERE"/state/ntfy 1000 1000
[ -e "$HERE"/state/ntfy/server.yml ] && rm "$HERE"/state/ntfy/server.yml
rsyncWithChownContent ~/Main/Other/NUC-services/service-data-unsynced/nextcloud/db "$HERE"/state/nextcloud/db 1000 1000
```