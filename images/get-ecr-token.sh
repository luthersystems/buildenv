#!/bin/bash

ECR_HOSTS=("$@")

DOCKER_CREDENTIAL_DESKTOP=$(which docker-credential-desktop)
DOCKER_CREDENTIAL_OSXKEYCHAIN=$(which docker-credential-osxkeychain)

# output the docker auth object for a given host.
#
# host_docker_auth will attempt to find auth objects in either the user's home
# directory (~/.docker) or the osx keychain.
function host_docker_auth() {
	HOST="$1"

	# MacOS handling
	POSSIBLE_BINS=("$DOCKER_CREDENTIAL_DESKTOP" "$DOCKER_CREDENTIAL_OSXKEYCHAIN")
	POSSIBLE_QUERIES=("$HOST" "https://$HOST")
	DOCKER_AUTH=""
	for BIN in ${POSSIBLE_BINS[*]}; do
		for QUERY in ${POSSIBLE_QUERIES[*]}; do
			if [ -n "$BIN" ]; then
				DOCKER_AUTH="$(echo "$QUERY" | "$BIN" get)"
				if [ "$?" -eq 0 ]; then
					echo $DOCKER_AUTH
					return 0
				fi
			fi
		done
	done

	# Linux handling

	# TODO: for now caching is broken on linux -- all host_docker_auth calls
	# output nothing, potentially causing excess logins

	return 1
}

function cache() {
	HOST="$1"
	DOCKER_AUTH=$(host_docker_auth "$HOST")
	if [ -n "$DOCKER_AUTH" ]; then
		DOCKER_TOKEN=$(echo "$DOCKER_AUTH" | jq -r .Secret)
	fi
	if [ -n "$DOCKER_TOKEN" ] && [ "$DOCKER_TOKEN" != "null" ]; then
		AWS_EXPIRATION_UNIX="$(echo "$DOCKER_TOKEN" | base64 -D | jq .expiration)"
	fi

	NOW=$(TZ=UTC date +%s)
	echo "ecr host:   $HOST"
	echo "expiration: $AWS_EXPIRATION_UNIX"
	echo "now:        $NOW"
	if [ -z "$AWS_EXPIRATION_UNIX" ] || [[ "$AWS_EXPIRATION_UNIX" -lt "$NOW" ]]; then
		echo "Docker client logging into host $HOST" 1>&2
		AWS_REGION="$(echo "$HOST" | awk -F. '{print $4};')"
		AWS_ACCOUNT_NUMBER="$(echo "$HOST" | awk -F. '{print $1};')"
		aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$HOST"
	else
		echo "Docker client already logged in with host $HOST" 1>&2
	fi
}

for i in "${ECR_HOSTS[@]}"; do
	cache $i
done
