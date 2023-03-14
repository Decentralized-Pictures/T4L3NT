#!/bin/sh

set -e

script_dir="$(cd "$(dirname "$0")" && echo "$(pwd -P)/")"
src_dir="$(dirname "$script_dir")"
cd "$src_dir"

. "$script_dir"/version.sh

image_name="${1:-tezos-}"
image_version="${2:-latest}"
build_deps_image_name=${3:-registry.gitlab.com/tezos/opam-repository}
build_deps_image_version=${4:-$opam_repository_tag}
executables=${5:-$(cat script-inputs/released-executables)}
commit_short_sha="${6:-$(git rev-parse --short HEAD)}"
commit_datetime="${7:-$(git show -s --pretty=format:%ci HEAD)}"
commit_tag="${8:-$(git describe --tags --always)}"

build_image_name="${image_name}build"

echo "Executables to include in Docker images:"
for executable in $executables; do
    echo "- $executable"
done

echo "### Building tezos..."

docker build \
  -t "$build_image_name:$image_version" \
  -f build.Dockerfile \
  --cache-from "$build_image_name:$image_version" \
  --build-arg "BASE_IMAGE=$build_deps_image_name" \
  --build-arg "BASE_IMAGE_VERSION=runtime-build-dependencies--$build_deps_image_version" \
  --build-arg "OCTEZ_EXECUTABLES=${executables}" \
  --build-arg "GIT_SHORTREF=${commit_short_sha}" \
  --build-arg "GIT_DATETIME=${commit_datetime}" \
  --build-arg "GIT_VERSION=${commit_tag}" \
  "$src_dir"

echo "### Successfully built docker image: $build_image_name:$image_version"

docker build \
  -t "${image_name}debug:$image_version" \
  --build-arg "BASE_IMAGE=$build_deps_image_name" \
  --build-arg "BASE_IMAGE_VERSION=runtime-dependencies--$build_deps_image_version" \
  --build-arg "BASE_IMAGE_VERSION_NON_MIN=runtime-build-dependencies--$build_deps_image_version" \
  --build-arg "BUILD_IMAGE=${build_image_name}" \
  --build-arg "BUILD_IMAGE_VERSION=${image_version}" \
  --build-arg "COMMIT_SHORT_SHA=${commit_short_sha}" \
  --target=debug \
  "$src_dir"

echo "### Successfully built docker image: ${image_name}debug:$image_version"

docker build \
  -t "${image_name}bare:$image_version" \
  --build-arg "BASE_IMAGE=$build_deps_image_name" \
  --build-arg "BASE_IMAGE_VERSION=runtime-dependencies--$build_deps_image_version" \
  --build-arg "BASE_IMAGE_VERSION_NON_MIN=runtime-build-dependencies--$build_deps_image_version" \
  --build-arg "BUILD_IMAGE=${build_image_name}" \
  --build-arg "BUILD_IMAGE_VERSION=${image_version}" \
  --build-arg "COMMIT_SHORT_SHA=${commit_short_sha}" \
  --target=bare \
  "$src_dir"


echo "### Successfully built docker image: ${image_name}bare:$image_version"

docker build \
  -t "${image_name%?}:$image_version" \
  --build-arg "BASE_IMAGE=$build_deps_image_name" \
  --build-arg "BASE_IMAGE_VERSION=runtime-dependencies--$build_deps_image_version" \
  --build-arg "BASE_IMAGE_VERSION_NON_MIN=runtime-build-dependencies--$build_deps_image_version" \
  --build-arg "BUILD_IMAGE=${build_image_name}" \
  --build-arg "BUILD_IMAGE_VERSION=${image_version}" \
  --build-arg "COMMIT_SHORT_SHA=${commit_short_sha}" \
  --target=minimal \
  "$src_dir"

echo "### Successfully built docker image: ${image_name%?}:$image_version"
