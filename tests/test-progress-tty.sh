#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-progress-tty.XXXXXX")

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

run_tty_check() {
    local script_path=$1
    local testing_name=$2
    local output_path=$3
    local runner_path=$project_dir/tests/progress-tty-runner.sh

    expect <<EXPECT >"$output_path"
log_user 1
set timeout 5
spawn "$runner_path" "$testing_name" "$script_path"
expect eof
catch wait result
exit [lindex \$result 3]
EXPECT

    grep -q 'interactive progress check' "$output_path"
    LC_ALL=C grep -q "$(printf '\033\[2K')" "$output_path"
}

command -v expect >/dev/null

run_tty_check "$project_dir/pdf-slim.sh" PDF_SLIM_TESTING \
    "$test_dir/pdf-slim.out"
run_tty_check "$project_dir/scan-clean.sh" SCAN_CLEAN_TESTING \
    "$test_dir/scan-clean.out"

printf '%s\n' 'interactive progress tests passed'
