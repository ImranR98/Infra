# Landscape

Docker-based setup for my self-hosted apps/services.

## Overview

- A home server runs several apps in Docker containers.
    - This includes [Immich](https://immich.app/), [Jellyfin](https://jellyfin.org/), [Home Assistant](https://www.home-assistant.io/), [ntfy](https://ntfy.sh/), etc.
    - All apps (with a few exceptions) are auto-updated by [Watchtower](https://containrrr.dev/watchtower/).
- Services are accessed via Traefik, which also provides TLS and various security features, including:
    - [Authelia](https://www.authelia.com/)
    - [CrowdSec](https://www.crowdsec.net/)
    - [Geoblock](https://plugins.traefik.io/plugins/62d6ce04832ba9805374d62c/geo-block) (for specific apps)
    - [mTLS](https://doc.traefik.io/traefik/https/tls/#client-authentication-mtls) (for specific apps)
- The home server has no public IP/ports, so requests to it are tunneled through a small cloud-based proxy server.
    - Request proxying is done with [FRP](https://github.com/fatedier/frp).
    - This has the additional benefit of hiding the home server's IP as all app domain/subdomain DNS entries point to the cloud proxy. 
- The cloud-based proxy also runs a few additional apps itself where appropriate (for example, [Syncthing Relay Server](https://docs.syncthing.net/users/strelaysrv.html)).

## Files

- Services are defined in Docker Compose files. Specifically:
    - `landscape.docker-compose.yaml`: Defines all services that run on the server (except FRPC).
    - `frpc.docker-compose.yaml`: Defines the FRPC service (this is separate because starting/stopping FRPC can be much riskier than for other services).
    - `landscape-remote.docker-compose.yaml`: Defines all services that run on the remote proxy.
- In order to have multiple instances of this setup (staging, production, etc.) and protect secret values from being checked in to Git, all environment-specific configuration and/or sensitive information is stored in environment-specific Git-ignored variable fles.
    - `template.VARS.sh`: Example file used as a starting point for a user to define their own `VARS.sh` containing environment-specific variables and secrets.
    - For the install script to run, at least one of the following user-defined files must exist (listed in order of preference):
        - `VARS.production.sh`
        - `VARS.staging.sh`
        - `VARS.sh`
- Setup scripts:
    - `install.sh` and `install_remote.sh`: Scripts used to install and start services on the server and remote proxy respectively.
    - `simple_restart.sh`: Restart a running service.
    - `update_frp.sh`: Check for FRPC/FRPS updates and install them if needed (auto-updating these is too risky).
- Other files:
    - `fixed.VARS.sh`: Hardcoded variables used by various scripts.
    - `prep_env.sh`: Helper script used by various other scripts.
    - Everything in `files/`: Various files used to configure/initialize apps and/or used by the install scripts.
    - Everything in `mock_data/`: Data used to demo some services in a staging environment.
        - Some services depend on a specific directory hierarchy on the server. For example, Immich looks for images in `Main/Media/Camera/`.
        - The `mock_data` folder reflects this hierarchy.
        - In production, the root of this hierarchy would be the user's home directory (instead of `mock-data/`).

## Usage

1. Create a copy of `template.VARS.sh` named `VARS.sh` (or `staging.VARS.sh` or `production.VARS.sh`). Fill in the values as appropriate.
2. Fork this repo and modify any of the source files as appropriate to fit your needs.
    - This is optional since all user/environment-specific information comes from the user-defined `VARS.sh` file.
    - But this repo is tailored to the author's needs - it is likely that you will at least want to disable certain apps or change some hardcoded app settings.
3. Set up a server with outbound internet access.
    - Most of the code is distro-agnostic but a few lines are not. We assume the server is running Fedora 41.
    - The server must be powerful enough to run all apps defined in `landscape.docker-compose.yaml`.
    - The server is assumed to have a LUKS-encrypted drive.
        - If this is not the case, comment out the lines in `install_remote.sh` related to FRPC preboot.
        - The boot process cannot complete without manual decrption of the drive. As part of `install_remote.sh`, a way to decrypt remotely via SSH will be set up.
    - The server must contain the following directories as defined in your `VARS.sh` file:
        1. `MAIN_PARENT_DIR`: Your data, used by the apps.
            - This is typically just your home directory.
            - All apps that work with your personal data (photos, notes, etc.) expect those files to be stored in a specific folder structure. You must provide that structure - use `mock-data/` as a template to copy from.
        2. `STATE_DIR`: Persistent internal storage/state for all apps.
            - Set to `./state/` by default.
            - Running services exclusively rely on this folder to store their internal data.
            - The folder and everything in it is auto-generated and should not be modified.
            - Significance of the data varies on a per-apps basis - some apps store ephemeral state while others store more important long-term data.
3. Set up a remote public-facing server reachable via SSH from your main server.
    - We assume this is running Ubuntu 24.04.
4. Set up DNS rules for all apps, each pointing to the remote proxy server's IP.
    - For a list of all required domains, define a `VARS.sh` file and then run: `source prep_env.sh; findDomainsInSetup`
5. Run `install_remote.sh`.
6. Run `install.sh`.