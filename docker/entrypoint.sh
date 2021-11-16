#!/usr/bin/env bash

setup.sh

supervisord -c /etc/supervisor/supervisord.conf -n
