#!/bin/sh

script_dir="$(cd "$(dirname "$0")" && echo "$(pwd -P)/")"

. "$script_dir"/version.sh

echo "## Checking installed dependencies..."
echo

if ! opam install opam/virtual/octez-deps.opam --deps-only --with-test --show-actions | grep "Nothing to do." > /dev/null 2>&1 ; then
    echo
    echo 'Failure! Missing actions:'
    echo
    opam install opam/virtual/octez-deps.opam --deps-only --with-test --show-actions
    echo
    echo 'Failed! Please read the doc in `./scripts/update_opam_repo.sh` and act accordingly.'
    echo
    exit 1
fi

echo '## Running `./scripts/update_opam_repo.sh`'
echo
./scripts/update_opam_repo.sh || exit 1

if [ -n "$(cat opam_repo.patch)" ] ; then

    echo "##################################################"
    cat opam_repo.patch
    echo "##################################################"

    echo 'Failed! The variables `opam_repository_tag` and `full_opam_repository_tag` are not synchronized. Please read the doc in `./scripts/update_opam_repo.sh` and act accordingly.'
    echo
    exit 1
fi

echo "Ok."
