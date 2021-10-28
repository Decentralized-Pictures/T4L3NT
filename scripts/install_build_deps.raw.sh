#! /bin/sh

script_dir="$(cd "$(dirname "$0")" && echo "$(pwd -P)/")"
src_dir="$(dirname "$script_dir")"

#shellcheck source=scripts/version.sh
. "$script_dir"/version.sh

opams=$(find "$src_dir/vendors" "$src_dir/src" -name \*.opam -print)

export OPAMYES=${OPAMYES:=true}

## In another ideal world, this list should be extracted from the pinned
## packages and filter only conf-* packages

# conf-rust is commented out because we need users to install a specific version of Rust.
# If we use opam depext, it will probably not install the right version.
# Note that install_build_deps.sh calls install_build_deps.rust.sh
# which checks whether Rust is installed with the right version and explains how
# to install it if needed, so using opam depext is redundant anyway.
opam depext conf-gmp conf-libev conf-pkg-config conf-hidapi ctypes-foreign conf-autoconf conf-libffi conf-zlib #conf-rust

## In an ideal world, `--with-test` should be present only when using
## `--dev`. But this would probably break the CI, so we postponed this
## change until someone have some spare time. (@pirbo, @hnrgrgr)

# here we cannot use double quotes because otherwise the list of opam packages
# will be intepreted as a string and not as a list of strings leading to
# an error.
# shellcheck disable=SC2086
opam install $opams --deps-only --with-test --criteria="-notuptodate,-changed,-removed"
