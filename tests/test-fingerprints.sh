#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-fingerprints.XXXXXX")
original_path=$PATH
real_shasum=$(command -v shasum)
real_openssl=$(command -v openssl)

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

input=$test_dir/input
printf '%s\n' 'fingerprint fixture' >"$input"
expected=$("$real_shasum" -a 256 <"$input")
expected=${expected%% *}

make_provider() {
    local directory=$1
    local name=$2
    local command_path=$3
    local arguments=$4

    mkdir -p "$directory"
    printf '#!/bin/sh\nexec %s %s "$@"\n' "$command_path" "$arguments" \
        >"$directory/$name"
    chmod +x "$directory/$name"
}

make_provider "$test_dir/shasum" shasum "$real_shasum" ''
make_provider "$test_dir/sha256sum" sha256sum "$real_shasum" '-a 256'
make_provider "$test_dir/openssl" openssl "$real_openssl" ''
mkdir "$test_dir/none"

use_provider_path() {
    export PATH=$1
}

check_providers() {
    local implementation=$1

    use_provider_path "$test_dir/shasum"
    [[ $(file_fingerprint "$input") == "$expected" ]]
    use_provider_path "$test_dir/sha256sum"
    [[ $(file_fingerprint "$input") == "$expected" ]]
    use_provider_path "$test_dir/openssl"
    [[ $(file_fingerprint "$input") == "$expected" ]]
    use_provider_path "$test_dir/none"
    if file_fingerprint "$input"; then
        printf '%s unexpectedly fingerprinted without a provider\n' \
            "$implementation" >&2
        exit 1
    fi
    PATH=$original_path
}

PDF_SLIM_TESTING=1
: "$PDF_SLIM_TESTING"
# shellcheck source=../pdf-slim.sh
# shellcheck disable=SC1091
source "$project_dir/pdf-slim.sh"
check_providers pdf-slim.sh

SCAN_CLEAN_TESTING=1
: "$SCAN_CLEAN_TESTING"
# shellcheck source=../scan-clean.sh
# shellcheck disable=SC1091
source "$project_dir/scan-clean.sh"
check_providers scan-clean.sh

printf '%s\n' 'fingerprint provider tests passed'
