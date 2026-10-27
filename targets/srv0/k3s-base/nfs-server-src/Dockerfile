# Replaces the archived ghcr.io/trexx/docker-nfs-server image (its GHCR
# package no longer has any tags or manifests). This reproduces the same
# minimal build: Alpine + nfs-utils + an entrypoint that starts rpc.nfsd and
# rpc.mountd in the host kernel. The deployment runs it privileged and mounts
# /var/lib/nfs/etab from the nfs-etab ConfigMap.
FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

RUN apk upgrade --no-cache \
 && apk add --no-cache nfs-utils

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0500 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
