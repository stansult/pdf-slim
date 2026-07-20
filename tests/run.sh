#!/usr/bin/env bash

set -o errexit
set -o nounset

test_dir=$(cd "$(dirname "$0")" && pwd)

for test_script in \
    test-conversion.sh \
    test-publication.sh \
    test-logging.sh \
    test-cli.sh \
    test-real-gs.sh
do
    "$test_dir/$test_script"
done

printf '%s\n' 'all tests passed'
