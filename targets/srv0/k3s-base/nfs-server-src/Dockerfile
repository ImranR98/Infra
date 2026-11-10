# Replaces the archived ghcr.io/trexx/docker-nfs-server image (its GHCR
# package no longer has any tags or manifests). This reproduces the same
# minimal build: Alpine + nfs-utils + an entrypoint that starts rpc.nfsd and
# rpc.mountd in the host kernel. The deployment runs it privileged and mounts
# /var/lib/nfs/etab from the nfs-etab ConfigMap.
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

RUN apk upgrade --no-cache \
 && apk add --no-cache nfs-utils

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0500 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
