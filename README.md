# Landscape

Docker-based setup for self-hosted apps/services.

## Overview

- A server runs several apps in Docker containers.
- Services are accessed via Traefik, which provides TLS and various security features, including:
    - [Authelia](https://www.authelia.com/)
    - [Geoblock](https://plugins.traefik.io/plugins/62d6ce04832ba9805374d62c/geo-block) (for specific apps)
- All apps are auto-updated by [Watchtower](https://containrrr.dev/watchtower/).

## Files

- Services are defined in `landscape.docker-compose.yaml`.
- All environment-specific configuration and/or sensitive information is stored in environment-specific Git-ignored variable files.
    - `template.VARS.sh`: Example file used as a starting point for a user to define their own `VARS.sh` containing environment-specific variables and secrets.
    - For the install script to run, at least one of the following user-defined files must exist (listed in order of preference):
        - `VARS.production.sh`
        - `VARS.staging.sh`
        - `VARS.sh`
- Setup scripts:
    - `install.sh`: Script used to install and start services.
    - `simple_restart.sh`: Restart a running service.
- Other files:
    - `fixed.VARS.sh`: Hardcoded variables used by various scripts.
    - `prep_env.sh`: Helper script used by various other scripts.
    - Everything in `files/`: Various files used to configure/initialize apps and/or used by the install scripts.
    - Everything in `mock_data/`: Data used to demo some services in a staging environment.

## Usage

1. Set up a server with outbound internet access.
    - Most of the code is distro-agnostic but a few lines are not. We assume the server is running [secureblue](https://secureblue.dev/) (should also work with other Fedora Atomic OSes and Workstation).
    - You must pre-install Docker and Docker compose.
2. Clone this repo on the server and create a copy of `template.VARS.sh` named `VARS.sh` (or `VARS.staging.sh` or `VARS.production.sh`). Fill in the values as appropriate.
3. Modify any of the source files in a fork of this repo, as appropriate to fit your needs.
4. Ensure the server contains the following directories as defined in your `VARS.sh` file:
    1. `MAIN_PARENT_DIR`: Your data, used by the apps.
        - This is typically just your home directory.
    2. `STATE_DIR`: Persistent internal storage/state for all apps.
        - Set to `./state/` by default.
        - Running services exclusively rely on this folder and/or named Docker volumes to store their internal data.
        - The folder and everything in it is auto-generated and should not be modified.
5. Purchase a domain for your apps, and set up DNS rules for each app subdomain, all pointing to the server's IP.
    - For a list of all required subdomains, run: `source prep_env.sh; findDomainsInSetup`
6. Run `install.sh` on the server to install all apps/services.
7. Some apps require manual initialization after they have been installed.
    - It is dangerous to publicly expose these apps without initializing them, since they may allow for unauthorized access.
    - For this reason, certain apps are temporarily protected with Authelia authentication middleware upon initial install, even when those apps would not usually be protected in their final post-initialization state (due to having their own authentication, or having specific client needs that are not compatible with Authelia).
    - At this stage, you must manually complete the setup process for each of these apps. For a list of these apps' domains, run the following command: `source prep_env.sh; cat files/authelia.config.yaml | envsubst | grep -Eo 'domain:.+# IGNORE INITIALLY' | awk '{print $2}'`
    - Once finished, re-run `install.sh`. This time, the Authelia middleware will not apply to those apps.
8. Setup is complete.
