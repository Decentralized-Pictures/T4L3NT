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

if [ ! -f "${NODE_DIR}/.h3_upgrade" ]; then
  printf "Setting config for upgrade\n"
  mv /tmp/config.json "$NODE_DIR"
  touch "${NODE_DIR}/.h3_upgrade"
fi;
