#!/usr/bin/env bash

set -e

script_dir="$(cd "$(dirname "$0")" && pwd -P)"

#shellcheck source=scripts/version.sh
. "$script_dir"/version.sh

# Install DAL trusted setup.
DAL_TRUSTED_SETUP="${OPAM_SWITCH_PREFIX}/share/dal-trusted-setup"
URL="https://f001.backblazeb2.com/file/shareshare"

echo "Installing DAL trusted setup in ${DAL_TRUSTED_SETUP}"
rm -rf "${DAL_TRUSTED_SETUP}"
mkdir -p "${DAL_TRUSTED_SETUP}"

curl -s -o "${DAL_TRUSTED_SETUP}"/srs_zcash_g1 "${URL}"/srs_zcash_g1
curl -s -o "${DAL_TRUSTED_SETUP}"/srs_zcash_g2 "${URL}"/srs_zcash_g2
