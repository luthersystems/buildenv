#!/usr/bin/env bash

die() { echo "$@" 1>&2; exit 1; }
which docker >/dev/null || die "docker not installed"
which jq >/dev/null || die "jq not installed"

docker version --format json | jq -r '.Server.Os + "/" + .Server.Arch'
