trap 'exit $?' ERR
set -x
sudo apt-get update
sudo apt-get install wget
export OPAMYES=true
export OPAMSOLVERTIMEOUT=1200
# [make sure opam has the latest repo]
# Note that in the docker image used for the test, the default repo is a local
# copy dating from when the image was generated.
opam repository set-url default https://opam.ocaml.org
opam update
# [install ocaml compiler]
wget -O latest-release:version.sh https://gitlab.com/tezos/tezos/raw/latest-release/scripts/version.sh
source latest-release:version.sh
opam switch create for_tezos $ocaml_version
eval $(opam env)
# [get system dependencies]
opam install depext
opam depext tezos
# [install tezos]
opam install tezos
