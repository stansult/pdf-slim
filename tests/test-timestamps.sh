#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-timestamps.XXXXXX")

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

PDF_SLIM_TESTING=1
: "$PDF_SLIM_TESTING" # Read by the sourced script.
# shellcheck source=../pdf-slim.sh
# shellcheck disable=SC1091
source "$project_dir/pdf-slim.sh"

reset_operational_output() {
    # These globals are consumed by functions in the sourced command.
    # shellcheck disable=SC2034
    OPERATIONAL_OUTPUT_STARTED=0
    # shellcheck disable=SC2034
    OPERATIONAL_START_DATE=''
    # shellcheck disable=SC2034
    OPERATIONAL_LAST_STREAM='stderr'
}

# Invoked indirectly by timestamp functions in the sourced command.
# shellcheck disable=SC2329
date() {
    case ${1:-} in
        +%Y-%m-%d) printf '%s\n' '2026-08-31' ;;
        +%H:%M:%S) printf '%s\n' '14:07:03' ;;
        *) command date "$@" ;;
    esac
}

reset_operational_output
{
    operational_message stdout 'processing: input.pdf'
    operational_message stdout 'created: output.pdf'
    finish_operational_output
} >"$test_dir/same-day.out"
printf '%s\n' \
    '[2026-08-31]' \
    '[14:07:03] processing: input.pdf' \
    '[14:07:03] created: output.pdf' >"$test_dir/same-day.expected"
cmp "$test_dir/same-day.expected" "$test_dir/same-day.out"

reset_operational_output
{
    operational_message stdout 'processing: input.pdf'
    # Invoked indirectly after replacing the first deterministic clock.
    # shellcheck disable=SC2329
    date() {
        case ${1:-} in
            +%Y-%m-%d) printf '%s\n' '2026-09-01' ;;
            +%H:%M:%S) printf '%s\n' '00:01:12' ;;
            *) command date "$@" ;;
        esac
    }
    operational_message stdout 'created: output.pdf'
    finish_operational_output
} >"$test_dir/cross-midnight.out"
printf '%s\n' \
    '[2026-08-31]' \
    '[14:07:03] processing: input.pdf' \
    '[00:01:12] created: output.pdf' \
    '[2026-09-01]' >"$test_dir/cross-midnight.expected"
cmp "$test_dir/cross-midnight.expected" "$test_dir/cross-midnight.out"

reset_operational_output
operational_block stderr $'first line\n\nthird line' \
    2>"$test_dir/multiline.err"
printf '%s\n' \
    '[2026-09-01]' \
    '[00:01:12] first line' \
    '' \
    '[00:01:12] third line' >"$test_dir/multiline.expected"
cmp "$test_dir/multiline.expected" "$test_dir/multiline.err"

printf '%s\n' 'timestamp tests passed'
