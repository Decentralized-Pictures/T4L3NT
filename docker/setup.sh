#!/usr/bin/env bash

CLIENT_DIR="${HOME}"/.tlnt-client
NODE_DIR="${HOME}"/.tlnt-node

if [ ! -d "${CLIENT_DIR}" ]; then
  mkdir "${CLIENT_DIR}";
fi;

if [ ! -d "${NODE_DIR}" ]; then
  printf "Initializing tlnt node config...\n"
  tlnt-node config init
  cp /tmp/config.json "$NODE_DIR"
fi;

if [ ! -d "${NODE_DIR}/context" ] && [ ! -d "${NODE_DIR}/store"  ] && [ ! -f "${NODE_DIR}/lock"  ]; then
  printf "Downloading and importing a rolling snapshot\n"
  wget https://s3.us-west-2.amazonaws.com/dcp.s3/snapshot.rolling
  tlnt-node snapshot import snapshot.rolling
  rm snapshot.rolling
fi;

if [ ! -f "${NODE_DIR}/.v12_upgrade" ]; then
  printf "Setting config for version 12 ithaca upgrade\n"
  mv /tmp/config.json "$NODE_DIR"
  touch "${NODE_DIR}/.v12_upgrade"
fi;
