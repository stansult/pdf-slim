#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-conversion.XXXXXX")
candidate=$test_dir/candidate.pdf
source_pdf=$test_dir/source.pdf

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

PDF_SLIM_TESTING=1
# shellcheck source=../pdf-slim.sh
source "$project_dir/pdf-slim.sh"

timeout_command=$(find_command timeout gtimeout)
fake_gs=$project_dir/tests/fake-gs.sh
printf '%s\n' '%PDF-1.7 fake input' >"$source_pdf"

FAKE_GS_MODE=success
export FAKE_GS_MODE
: >"$candidate"
convert_pdf "$source_pdf" "$candidate" "$timeout_command" "$fake_gs" 1s 0
[[ -s $candidate ]]
remove_candidate "$candidate"

FAKE_GS_MODE=failure
: >"$candidate"
if convert_pdf "$source_pdf" "$candidate" "$timeout_command" "$fake_gs" 1s 0; then
    printf '%s\n' 'expected nonzero Ghostscript status to fail' >&2
    exit 1
fi
[[ ! -e $candidate ]]

FAKE_GS_MODE=partial-failure
: >"$candidate"
if convert_pdf "$source_pdf" "$candidate" "$timeout_command" "$fake_gs" 1s 0; then
    printf '%s\n' 'expected partial output with nonzero status to fail' >&2
    exit 1
fi
[[ ! -e $candidate ]]

FAKE_GS_MODE=empty
: >"$candidate"
if convert_pdf "$source_pdf" "$candidate" "$timeout_command" "$fake_gs" 1s 0; then
    printf '%s\n' 'expected empty output to fail validation' >&2
    exit 1
fi
[[ ! -e $candidate ]]

FAKE_GS_MODE=sleep
: >"$candidate"
if convert_pdf "$source_pdf" "$candidate" "$timeout_command" "$fake_gs" 0.1s 0; then
    printf '%s\n' 'expected timeout to fail' >&2
    exit 1
fi
[[ ! -e $candidate ]]

printf '%s\n' 'conversion tests passed'
