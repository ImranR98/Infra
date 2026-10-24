# Replaces the archived ghcr.io/trexx/docker-nfs-server image (its GHCR
# package no longer has any tags or manifests). This reproduces the same
# minimal build: Alpine + nfs-utils + an entrypoint that starts rpc.nfsd and
# rpc.mountd in the host kernel. The deployment runs it privileged and mounts
# /var/lib/nfs/etab from the nfs-etab ConfigMap.
FROM alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412

RUN apk add --no-cache nfs-utils=2.6.4-r4

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0500 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
