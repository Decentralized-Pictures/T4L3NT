#!/bin/sh

# This script launches a sandbox node, activates Granada, gets the RPC descriptions
# as JSON, and converts this JSON into an OpenAPI specification.
# You must compile the node and the client before running it.
#
# This script is mimicked by tests_python/tests/test_openapi.py
# When the python tests framework becomes a standalone library, this script
# should be removed and replaced by a python script calling the test's core
# logic.

# Ensure we are running from the root directory of the Tezos repository.
cd "$(dirname "$0")"/../.. || exit

# Tezos binaries.
tezos_node=./tezos-node
tezos_client=./tezos-client

# Protocol configuration.
protocol_hash=PtJakart2xVj7pYXJBXrqHgd82rdkLey5ZeeGwDgPp9rhQUbSqY
protocol_parameters=src/proto_013_PtJakart/parameters/sandbox-parameters.json
protocol_name=jakarta

# Secret key to activate the protocol.
activator_secret_key="unencrypted:edsk31vznjHSSpGExDMHYASz45VZqXN4DPxvsa4hAyY8dHM28cZzp6"

# RPC port.
rpc_port=8732

# Temporary files.
tmp=openapi-tmp
data_dir=$tmp/tezos-sandbox
client_dir=$tmp/tezos-client
api_json=$tmp/rpc-api.json
proto_api_json=$tmp/proto-api.json
mempool_api_json=$tmp/mempool-api.json

# Generated files.
openapi_json=docs/api/rpc-openapi.json
proto_openapi_json=docs/api/$protocol_name-openapi.json
mempool_openapi_json=docs/api/$protocol_name-mempool-openapi.json

# Get version number.
version=$(dune exec tezos-version)

# Start a sandbox node.
$tezos_node config init --data-dir $data_dir \
    --network sandbox \
    --expected-pow 0 \
    --rpc-addr localhost:$rpc_port \
    --no-bootstrap-peer \
    --synchronisation-threshold 0
$tezos_node identity generate --data-dir $data_dir
$tezos_node run --data-dir $data_dir &
node_pid="$!"

# Wait for the node to be ready (sorry for the hackish way...)
sleep 1

# Activate the protocol.
mkdir $client_dir
$tezos_client --base-dir $client_dir import secret key activator $activator_secret_key
$tezos_client --base-dir $client_dir activate protocol $protocol_hash \
    with fitness 1 \
    and key activator \
    and parameters $protocol_parameters \
    --timestamp "$(TZ='AAA+1' date +%FT%TZ)"

# Wait a bit again...
sleep 1

# Get the RPC descriptions.
curl "http://localhost:$rpc_port/describe/?recurse=yes" > $api_json
curl "http://localhost:$rpc_port/describe/chains/main/blocks/head?recurse=yes" > $proto_api_json
curl "http://localhost:$rpc_port/describe/chains/main/mempool?recurse=yes" > $mempool_api_json

# Kill the node.
kill -9 "$node_pid"

# Remove RPC starting with "/private/"
clean_private_rpc () {
  jq 'delpaths([paths | select(.[-1] | strings | startswith("/private/"))])'
}

# Convert the RPC descriptions.
dune exec src/bin_openapi/rpc_openapi.exe -- "$version" $api_json | clean_private_rpc "$@" > $openapi_json
echo "Generated OpenAPI specification: $openapi_json"
dune exec src/bin_openapi/rpc_openapi.exe -- "$version" $proto_api_json | clean_private_rpc "$@" > $proto_openapi_json
echo "Generated OpenAPI specification: $proto_openapi_json"
dune exec src/bin_openapi/rpc_openapi.exe -- "$version" $mempool_api_json | clean_private_rpc "$@" > $mempool_openapi_json
echo "Generated OpenAPI specification: $mempool_openapi_json"
echo "You can now clean up with: rm -rf $tmp"
