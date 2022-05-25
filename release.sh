#!/usr/bin/env bash

set -o xtrace
set -o errexit
set -o nounset
set -o pipefail

if [ ! -d ./.git ]
then
  echo "not in root directory"
  exit 1
fi

if [ ! -z "$(git status --porcelain)" ]
then
  echo "working directory is not clean"
  exit 1
fi

if [ "$(git rev-parse --abbrev-ref HEAD)" != "master" ]
then
  echo "not on master"
  exit 1
fi

git pull

PROJECT="$(cat ./common.mk | egrep '^PROJECT=' | sed -e 's/PROJECT=//')"
VERSION="$(cat ./common.mk | egrep '^VERSION=')"
# check that the version is formatted as we expect
echo "$VERSION" | egrep '^VERSION=[0-9]+\.[0-9]+\.[0-9]+-SNAPSHOT$'
VERSION="$(echo "$VERSION" | gcut -d "=" -f 2)"
VERSION="$(echo "$VERSION" | gcut -d "-" -f 1)"
VERSION_MAJOR="$(echo "$VERSION" | gcut -d "." -f 1)"
VERSION_MINOR="$(echo "$VERSION" | gcut -d "." -f 2)"
VERSION_PATCH="$(echo "$VERSION" | gcut -d "." -f 3)"
function set_version()
{
  gsed -i -e 's/^VERSION=.*$/VERSION='"$1"'/' ./common.mk
}

VERSION_THIS="$VERSION_MAJOR"."$VERSION_MINOR"."$VERSION_PATCH"
VERSION_NEXT="$VERSION_MAJOR"."$VERSION_MINOR"."$(( (VERSION_PATCH + 1) ))"-SNAPSHOT

STAMP="$(date +%ss)"
git checkout -b                releases/"$PROJECT"/"$VERSION_THIS"/"$STAMP"
git push --set-upstream origin releases/"$PROJECT"/"$VERSION_THIS"/"$STAMP"

set_version "$VERSION_THIS"
git commit -a -m 'Create release version '"$VERSION_THIS"
git tag -a -f -m 'Release '"$VERSION_THIS" v"$VERSION_THIS"

make -C images
make -C images docker-push

set_version "$VERSION_NEXT"
git commit -a -m 'Set version to '"$VERSION_NEXT"

set +o xtrace
echo "Remember, you must still push tags, push branch, create pull request, and change branches ..."
echo "+OK (release.sh)"
