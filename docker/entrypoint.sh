#!/usr/bin/env bash

setup.sh

exec supervisord -c /etc/supervisor/supervisord.conf -n
