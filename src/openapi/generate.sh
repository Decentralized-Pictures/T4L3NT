#!/bin/sh

# This script launches a sandbox node, activates Delphi, gets the RPC descriptions
# as JSON, and converts this JSON into an OpenAPI specification.
# You must compile the node and the client before running it.
#
# This script is mimicked by tests_python/tests/test_openapi.py
# When the python tests framework becomes a standalone library, this script
# should be removed and replaced by a python script calling the test's core
# logic.

# Ensure we are running from the root directory of the Tezos repository.
cd "$(dirname "$0")"/../..

# Tezos binaries.
tezos_node=./tezos-node
tezos_client=./tezos-client

# Protocol configuration.
protocol_hash=PsDELPH1Kxsxt8f9eWbxQeRxkjfbxoqM52jvs5Y5fBxWWh4ifpo
protocol_parameters=src/proto_007_PsDELPH1/parameters/sandbox-parameters.json
protocol_name=delphi

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

# Generated files.
openapi_json=docs/api/rpc-openapi.json
proto_openapi_json=docs/api/$protocol_name-openapi.json

# Get version number.
version=$(ocaml scripts/print_version.ml)

# Start a sandbox node.
$tezos_node config init --data-dir $data_dir \
    --network sandbox \
    --expected-pow 0 \
    --rpc-addr localhost:$rpc_port \
    --no-bootstrap-peer
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
    --timestamp $(TZ='AAA+1' date +%FT%TZ)

# Wait a bit again...
sleep 1

# Get the RPC descriptions.
curl "http://localhost:$rpc_port/describe/?recurse=yes" > $api_json
curl "http://localhost:$rpc_port/describe/chains/main/blocks/head?recurse=yes" > $proto_api_json

# Kill the node.
kill -9 "$node_pid"

# Convert the RPC descriptions.
dune exec src/openapi/rpc_openapi.exe -- $version $api_json > $openapi_json
echo "Generated OpenAPI specification: $openapi_json"
dune exec src/openapi/rpc_openapi.exe -- $version $proto_api_json > $proto_openapi_json
echo "Generated OpenAPI specification: $proto_openapi_json"
echo "You can now clean up with: rm -rf $tmp"
