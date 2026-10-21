#!/bin/sh
# Entrypoint of luthersystems/dind: clears a legacy BuildKit cache, then runs
# the upstream entrypoint unchanged.
#
# The fabric-peer chart keeps /var/lib/docker on a persistent volume. A volume
# that Docker 19.03 used holds BuildKit v1 cache metadata
# (buildkit/metadata.db), and Docker 29 refuses to start on it ("legacy (v1)
# cache metadata found ... needs to be removed or migrated"). The directory
# holds only build cache, so removing it costs one uncached chaincode build;
# images and containers are kept (#159).
set -eu

buildkit=/var/lib/docker/buildkit
if [ -f "$buildkit/metadata.db" ]; then
	echo "dind-entrypoint: removing the legacy BuildKit cache in $buildkit" >&2
	rm -rf "$buildkit"
fi

exec dockerd-entrypoint.sh "$@"
