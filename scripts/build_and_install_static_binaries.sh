#!/usr/bin/env sh

# Used in the CI to build and install the static binaries.

set -eu

if [ $# -ne 1 ]; then
    echo "usage: $0 DESTDIR"
    exit 1
fi

tmp_dir=$(mktemp -dt tezos_static_install.XXXXXXXX)
cleanup () {
    set +e
    echo Cleaning up...
    rm -rf "$tmp_dir"
}
trap cleanup EXIT INT

# shellcheck disable=SC2046
dune build   --profile static $(xargs -I {} echo {}.install < script-inputs/static-packages)
# shellcheck disable=SC2046
dune install --profile static --prefix "$tmp_dir" $(cat script-inputs/static-packages)
mv "$tmp_dir/bin" "$1"
