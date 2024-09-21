# Landscape

Kubernetes cluster setup for my self-hosted apps/services.

## Overview

- The cluster is not directly exposed to the internet (due to the availability of port forwarding not being guaranteed in all environments).
    - Instead, [FRP](https://github.com/fatedier/frp) is used to forward requests from a remote public-facing proxy server to the main control plane node (where is is picked up by Traefik or other apps listening on specified ports).
    - This does mean the main control plane node is the entrypoint for all requests.
    - A select few apps may run on the remote proxy server itself.
- Everything is automated as much as possible; [IaC](https://en.wikipedia.org/wiki/Infrastructure_as_code) FTW.

## Components

- A "component" is the term for a set of things (K8s objects, Docker images, scripts, etc.) in the infrasturcture that are tied to a distinct entity or that serve a distinct purpose.
    - For example, any hosted app that runs on the cluster is a component, but the cluster itself is also a component, and so are the FRP server and client.
    - Another example of a component is `common-pv` - the set of K8s PVs that are generally used across the cluster (not tied to a specific component).
    - Most components install to the K8s cluster, with a few exceptions like FRPC and Syncthing, which run separately as Docker containers.
- Everything in a component is installed and updated together as one unit.
- Some components are completely independent and can be added/removed without affecting the rest of the system (this is usually the case), but others (like `traefik` or `frpc`) are not. Thus, some components need to be installed in a specific order.
- Each component is stored in its own directory.
    - Some component may have subcomponents in subdirectories - these are components that overlap enough (share enough files) with their parent components and therefore benefit from being part of the same "unit", but are still different enough to be installed and updated separately.
    - With rare exceptions, all directories in the root of this repo are component directories.

### Installing Components

- The `install_component.sh` script, given a component directory, installs or updates that component using the files inside.
    - Some files have special purposes and are installed in a specific order and method as decided by the script (for example `prep.sh` or `values.yaml`).
    - All files in the component directory that do not have a special pre-defined purpose is processed in one of these ways (in alphabetical order):
        - All `sh` files are executed.
        - All `yaml` files are applied as K8s manifests.
        - All other files and subdirectories are ignored.
    - The script can be run with the `-u` option to apply updates (this changes what files are processed and how).
    - The script can be run with the `-r` option to remove/uninstall some components (where available).
- The `generate_setup_script.sh` file is used to generate a set of `install_component.sh` (and other) commands in the correct order and using the correct parameters to setup or update everything.

### Variables

- While the overall structure of the cluster (apps deployed, apps configs, etc.) are hardcoded, many per-environment variables are defined in `VARS.sh` (each environment - staging, production, etc. - can have its own version of this file).
- When a component is being installed, the `install_component.sh` script passes the variables on to any child shell scripts, and replaces the variables in any `yaml` files using the `envsubst` command.
- This means that the scripts and `yaml` files in the component subdirectories should never be applied directly - anytime you need to install or make changes to a component, you must use `install_component.sh` to apply those changes (if you really need to run apply a specific file manually, you need to `source VARS.sh` first, then run the file through `envsubst`).
- Examples of dynamic variables include:
    - The domain names for all apps.
    - The username and hostname of the public-facing proxy server.
    - Some "secret" values such as some apps' DB credentials, default initial login credentials for some apps, the Cloudflare token, various app config values (such as Ntfy webhook URLs), etc. 
    - Path to the `Main/` directory and any subdirectories needed by various apps.
- Aside from variables, image tags are replaced by dynamically fetched image hash values during install time by `install_component.sh`. This is useful because it [avoids the use of `imagePullPolicy: Always`](https://kubernetes.io/docs/concepts/containers/images/#image-pull-policy) and avoids rate limiting and version ambiguity issues.
    - This is another reason for never trying to apply `yaml` files directly - let `install_component.sh` handle it.
    - Note that this only applies to Docker Hub images for now.

## Usage

### Prerequisites

- A Fedora server with internet access.
    - The server is assumed to have a LUKS-encrypted drive (if this is not the case, skip the `frpc-preboot` step during setup).
    - While K8s infrastructure is distro-agnostic, the K8s install script itself runs on Fedora. Some pod securityContext options have also been written with SELinux in mind (default on Fedora). 
- A "main" node that will be the first control plane node for your K8s cluster.
    - For now, this is also the "main storage" node that holds the `~/Main/` and `./state/` directories (in the future this could be a separate dedicated node).
    - The main storage directories are:
        - `Main/` (typically but not necessarily in `~/Main`): All your personal files (media, notes, documents, everything).
            - Irreplaceable - only provide to containers that need it, and use the `subPath` option when possible to limit access.
            - Ensure it has the directory structure expected by the apps that use it.
            - This directory and any required subdirectories must already exist before you begin setup - they are not automatically created.
        - `./state/` (always relative to this repo): Persistent storage/state for all apps (each apps can have a subdirectory here that is mounted with the `subPath` option).
            - Significance of the data varies on a per-apps basis - some apps store ephemeral state while others store more important long-term data.
    - Apps that need to access persistent storage can only run on the main storage node.
        - This is fine for most apps, but any apps that must run on other nodes should be able to access storage via an NFS share (which would have to be setup as needed).
        - In the future it might make sense to use a dedicated storage node that serves everything via NFS 
- Any other nodes (optional) must be network-accessible.
- A remote public-facing server reachable via SSH from your main node.
- DNS rules already in place (point all required domains to the remote proxy). For a list of all required domains, run: `source helpers.sh; findDomainsInSetup`
- CloudFlare DNS must be used so that the HTTPS challenge passes. So a valid Cloudflare token is required.

# Steps

1. Modify `VARS.sh` as needed.
2. Run `generate_setup_script.sh > temp.sh` and run the resulting `temp.sh` script.
    - If the K8s cluster has multiple nodes, the current machine is the control plane. You must join all worker nodes manually after the K8s install step (the script pauses at this point).
3. If all goes well, periodically update the components by running `generate_setup_script.sh > temp.sh` with the `-u` (update) parameter and running the resulting `temp.sh` script.

# Adding New Components

- At minimum, there should be a `yaml` containing a deployment, or an `install.sh` containing `helm` commands.
- An `update.sh` should be provided in all cases except rare exceptions where "update" makes no sense.
- Other `yaml` and `sh` files can be added as needed (see `install_component.sh` for details).
    - Note that only files in the top level of the component directory are directly used by that script - subdirectories are ignored.
- It is good practice to include an `uninstall.sh` as well.

# Some Useful Commands

```bash
# Run a temporary pod (in this case, Alpine with the pkg package manager)
kubectl run curlpod --image=alpine --restart=Never --rm -it -- /bin/sh # Then apk add --no-cache curl
# Shell into a pod
kubectl exec -it <pod-name> --stdin --tty -- bash
# Reset the cluster (be careful with this one)
sudo kubeadm --cri-socket unix:///var/run/crio/crio.sock reset && sudo rm -r /etc/cni/net.d
# Run a temporary pod with a custom security context (ping neeeds this for example as seen below)
kubectl run --rm -i --tty alpine-ping --image=alpine --restart=Never --overrides='
{
  "apiVersion": "v1",
  "spec": {
    "nodeSelector": { "kubernetes.io/hostname": "box" },
    "containers": [
      {
        "name": "alpine-ping",
        "image": "alpine",
        "command": ["/bin/sh", "-c", "apk add --no-cache iputils && ping -c 4 10.96.0.10"],
        "securityContext": {
          "runAsUser": 0,
          "privileged": true
        }
      }
    ]
  }
}' -- /bin/sh
# Join node
kubeadm token create --print-join-command # May need to run the actual join command with --cri-socket unix:///var/run/crio/crio.sock
# Remove node
kubectl drain nodename --ignore-daemonsets --delete-local-data
kubectl delete node nodename
```