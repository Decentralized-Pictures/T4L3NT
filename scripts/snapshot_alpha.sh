#! /usr/bin/env bash

set -e

usage="Usage:

$ ./scripts/snapshot_alpha.sh <name>_<version_number>
Packs the current proto_alpha directory in a new
proto_<version_number>_<hash> directory with all the necessary
renamings."

script_dir="$(cd "$(dirname "$0")" && echo "$(pwd -P)/")"
cd "$script_dir"/..

current=$1
label=$(echo $current | cut -d'_' -f1)
version=$(echo $current | cut -d'_' -f2)

if ! ( [[ "$label" =~ ^[a-z]+$ ]] && [[ "$version" =~ ^[0-9][0-9][0-9]$ ]] ); then
    echo "Wrong protocol version."
    echo
    echo "$usage"
    exit 1
fi

if [ -d src/proto_${version} ] ; then
    echo "Error: you should remove the directory 'src/proto_${version}'"
    exit 1
fi

# create a temporary directory until the hash is known
# this is equivalent to `cp src/proto_alpha/ src/proto_${version}` but only for versioned files
mkdir /tmp/tezos_proto_snapshot
git archive HEAD src/proto_alpha/ | tar -x -C /tmp/tezos_proto_snapshot
mv /tmp/tezos_proto_snapshot/src/proto_alpha src/proto_${version}
rm -rf /tmp/tezos_proto_snapshot

# set current version
sed -i.old.old -e 's/let version_value = "alpha_current"/let version_value = "'${current}'"/' \
    src/proto_${version}/lib_protocol/raw_context.ml

long_hash=$(./tlnt-protocol-compiler -hash-only src/proto_${version}/lib_protocol)
short_hash=$(echo $long_hash | head -c 8)

if [ -d src/proto_${version}_${short_hash} ] ; then
    echo "Error: you should remove the directory 'src/proto_${version}_${short_hash}'"
    exit 1
fi

mv src/proto_${version} src/proto_${version}_${short_hash}


# move daemons to a tmp directory to avoid editing lib_protocol
cd src/proto_${version}_${short_hash}
daemons=$(ls | grep -v lib_protocol)
mkdir tmp
mv $daemons tmp
cd tmp

# rename main_*.ml{,i} files of the binaries
for file in $(find . -name main_\*.ml -or -name main_\*.mli)
do
    mv "$file" $(echo "$file" | sed s/_alpha/_${version}_${short_hash}/g)
done


# rename .opam files
for file in $(find . -name \*.opam)
do
    mv "$file" $(echo "$file" | sed s/alpha/${version}-${short_hash}/g)
done

# fix content of dune and opam files
sed -i.old -e s/_alpha/_${version}_${short_hash}/g \
       -e s/-alpha/-${version}-${short_hash}/g \
    $(find . -name dune -or -name \*.opam)

mv $daemons ..
cd ..
rmdir tmp

cd lib_protocol

# replace fake hash with real hash, this file doesn't influence the hash
sed -i.old -e 's/"hash": "[^"]*",/"hash": "'$long_hash'",/' \
    TEZOS_PROTOCOL

sed -i.old -e s/protocol_alpha/protocol_${version}_${short_hash}/ \
           -e s/protocol-alpha/protocol-${version}-${short_hash}/ \
    $(find . -type f)

sed -i.old -e s/-alpha/-${version}-${short_hash}/ \
           -e s/_alpha/_${version}_${short_hash}/ \
    $(find . -type f -name dune)

# replace fist the template call with underscore version,
# then the other occurrences with dash version
sed -i.old -e 's/"alpha"/"'${version}_${short_hash}'"/' \
           -e 's/alpha/'${version}-${short_hash}'/' \
    $(find . -name \*.opam)

for file in  $(find . -name \*.opam)
do
    mv "$file" $(echo "$file" | sed s/alpha/${version}-${short_hash}/g)
done

dune exec ../../lib_protocol_compiler/replace.exe ../../lib_protocol_compiler/dune_protocol.template dune.inc ../../lib_protocol_compiler/final_protocol_versions ${version}_${short_hash}

cd ..

# remove files generated by sed
find . -name '*.old' -exec rm {} \;

if [ -z "$SILENCE_REMINDER" ]; then
  echo "Generated src/proto_${version}_${short_hash}. Don't forget to:"
  echo ""
  echo "  ./scripts/update_unit_test.sh"
  echo "  ./scripts/update_integration_test.sh"
  echo "  ./scripts/update_opam_test.sh"
fi
