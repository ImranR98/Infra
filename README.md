# Landscape

Docker-based setup for my self-hosted apps/services.

## Overview

- The host is not directly exposed to the internet (due to the availability of port forwarding not being guaranteed in all environments).
    - Instead, [FRP](https://github.com/fatedier/frp) is used to forward requests from a remote public-facing proxy server.
    - A select few apps may run on the remote proxy server itself.
- Files:
    - `landscape.docker-compose.yaml`: Defines all services that run on the host (except FRPC).
    - `frpc.docker-compose.yaml`: Defines the FRPC service (this is separate as starting/stopping FRPC can be much riskier than for other services).
    - `landscape-remote.docker-compose.yaml`: Defines all services that run on the remote proxy.
    - `template.VARS.sh`: Example file used as a starting point for a user to define their own `VARS.sh` containing environment-specific variables and secrets.
        - In order to re-use this setup across multiple environments (staging, production, etc.), nothing commited to Git includes any hardcoded values that are environment-specific or otherwise sensitive, like domain names or secrets.
        - Instead, such variables are defined in a `VARS.sh` file (each environment can have its own version of this file).
    - `fixed.VARS.sh`: Hardcoded variables used by various scripts. Do not change.
    - `prep_env.sh`: Helper script used by various other scripts.
    - `install.sh` and `install_remote.sh`: Scripts used to install and start services on the host and remote proxy respectively.
    - Everything in `files/`: Various files used to initialize service states or used by the install scripts.
    - Everything in `state/`: Running services exclusively rely on this folder. Everything in it is auto-generated and should not be modified. Note the folder itself may not exist on a fresh clone of the repo.
    - Everything in `mock_data/`: Data used to demo some services in a staging environment.
        - Some services depend on data on the host that is expected to be there in a specific directory hierarchy.
        - The `mock_data` folder reflects this hierarchy, except in production the folder would typically be the user's home directory.

## Usage

### Prerequisites

- A server with internet access.
    - The server is assumed to have a LUKS-encrypted drive (if this is not the case, comment out the lines in `install_remote.sh` related to FRPC preboot).
    - Most of the code is distro-agnostic, a few lines are not. We assume the host is running Fedora 41 and the remote proxy is on Ubuntu 24.04.
- The following directory structure on the host:
    1. `MAIN_PARENT_DIR` (usually just your home directory): All your personal files (media, notes, documents, everything).
        - Irreplaceable - only provide to containers that need it, and use the `subPath` option when possible to limit access.
        - Ensure it has the directory structure expected by the apps that use it (for example, the `Main` `Phone Sync Folder` subdirectories - see `mock-data/` for example).
    2. `STATE_DIR` (`./state/` by default): Persistent storage/state for all apps.
        - Significance of the data varies on a per-apps basis - some apps store ephemeral state while others store more important long-term data.
- A remote public-facing server reachable via SSH from your main host.
- DNS rules already in place (point all required domains to the remote proxy). For a list of all required domains, run: `source prep_env.sh; findDomainsInSetup`

# Steps

1. Create a copy of `template.VARS.sh` named `VARS.sh` (or `staging.VARS.sh` or `production.VARS.sh`). Fill in the values as appropriate.
2. Run `install_remote.sh`.
3. Run `install.sh`.