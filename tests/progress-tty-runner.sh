#!/usr/bin/env bash

set -o errexit
set -o nounset

export "$1=1"
# shellcheck disable=SC1090
source "$2"
progress_start 'interactive progress check'
sleep 0.4
progress_finish
