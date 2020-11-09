#! /usr/bin/env bash

set -e

usage="Usage:
$ ./scripts/link_protocol.sh src/proto_<version_number>_<short_hash>

Inserts the protocol with the given version number and short hash in the right
files of the build system to compile it, and replaces the occurrences of

   proto_<predecessor_version_number>_<predecessor_short_hash>

in the code by

   proto_<predecessor_version_number>_<predecessor_short_hash>
   proto_<version_number>_<short_hash>
"

script_dir="$(cd "$(dirname "$0")" && echo "$(pwd -P)/")"
cd "$script_dir"/..

if [ ! -d "$1" ]; then
    echo "$usage"
    exit 1
fi

new_version=$(basename $1 | awk -F'_' '{print $2}')
new_hash=$(basename $1 | awk -F'_' '{print $3}')
full_hash=$(jq .hash < $1/lib_protocol/TEZOS_PROTOCOL)
replacement=${new_version}-${new_hash}
if [[ -z "${new_version}" || -z "${new_hash}" || -z "${full_hash}" ]] ; then
    echo "$usage"
    exit 1
fi

# The pattern to look for is "00X-<hash>".
# Once found it's either replaced or the line is duplicated and then replaced
old_version=$( printf '%03d' $(($new_version -1)) )
old_dir=$(ls -d src/proto_${old_version}_*)
old_hash=$(basename $old_dir | awk -F'_' '{print $3}')
pattern=${old_version}-${old_hash}

# if a line matches PATTERN, a new line is printed where the pattern is replaced
duplicate_and_replace() {
    PATTERN=$1
    REPLACEMENT=$2
    shift 2

    awk -i inplace '{
        print
        if ($0 ~ PATTERN) {
           sub(PATTERN,REPLACEMENT)
           print
        }}' PATTERN=$PATTERN REPLACEMENT=$REPLACEMENT $*
}

duplicate_and_replace_when_2_occ() {
    PATTERN=$1
    REPLACEMENT=$2
    shift 2

    awk -i inplace '{
        print
        if (prevlast ~ pattern && last ~ PATTERN && $0 !~ PATTERN) {
           sub(PATTERN,REPLACEMENT,prevlast)
           sub(PATTERN,REPLACEMENT,last)
           {print prevlast}
           {print last}
           print
        }
        {prevlast = last}
        {last = $0}

       }' PATTERN=$PATTERN REPLACEMENT=$REPLACEMENT $*
}

# the minimum needed, although you can't bake
duplicate_and_replace ${pattern} ${replacement} active_protocol_versions

# activate in client to bake and use RPCs
duplicate_and_replace -${pattern} -${replacement} \
    src/bin_client/tezos-client.opam
duplicate_and_replace_when_2_occ -${pattern} -${replacement} \
    src/bin_client/dune

# activate in node
duplicate_and_replace_when_2_occ -${pattern} -${replacement} \
    src/bin_node/dune
duplicate_and_replace -${pattern} -${replacement} \
    src/bin_node/tezos-node.opam
duplicate_and_replace -${pattern} -${replacement} \
    src/bin_validation/{dune,tezos-validator.opam}