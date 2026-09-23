#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-concurrent-logging.XXXXXX")
fake_gs_pid=''

cleanup() {
    if [[ -n $fake_gs_pid ]] && kill -0 "$fake_gs_pid" 2>/dev/null; then
        kill "$fake_gs_pid" 2>/dev/null || true
        wait "$fake_gs_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

fake_gs=$project_dir/tests/fake-gs.sh
ready_file=$test_dir/ready
release_file=$test_dir/release
output_file=$test_dir/output.pdf

FAKE_GS_MODE=success \
FAKE_GS_READY_FILE=$ready_file \
FAKE_GS_RELEASE_FILE=$release_file \
FAKE_GS_BARRIER_ATTEMPTS=50 \
    "$fake_gs" "-sOutputFile=$output_file" &
fake_gs_pid=$!

ready_attempt=0
while [[ ! -e $ready_file ]]; do
    if ! kill -0 "$fake_gs_pid" 2>/dev/null; then
        printf '%s\n' 'fake Ghostscript exited before signaling readiness' >&2
        wait "$fake_gs_pid" || true
        exit 1
    fi
    if ((ready_attempt >= 50)); then
        printf '%s\n' 'timed out waiting for fake Ghostscript readiness' >&2
        exit 1
    fi
    sleep 0.1
    ((ready_attempt += 1))
done

kill -0 "$fake_gs_pid" 2>/dev/null
[[ ! -e $output_file ]]
: >"$release_file"
wait "$fake_gs_pid"
fake_gs_pid=''
[[ -s $output_file ]]
grep -q '^%PDF-' "$output_file"

timeout_ready=$test_dir/timeout-ready
timeout_release=$test_dir/timeout-release
timeout_output=$test_dir/timeout-output.pdf
if FAKE_GS_MODE=success \
    FAKE_GS_READY_FILE=$timeout_ready \
    FAKE_GS_RELEASE_FILE=$timeout_release \
    FAKE_GS_BARRIER_ATTEMPTS=2 \
    "$fake_gs" "-sOutputFile=$timeout_output" \
    >"$test_dir/timeout.stdout" 2>"$test_dir/timeout.stderr"
then
    printf '%s\n' 'expected the fake Ghostscript barrier to time out' >&2
    exit 1
fi
[[ -e $timeout_ready ]]
[[ ! -e $timeout_output ]]
grep -q 'timed out waiting for release file' "$test_dir/timeout.stderr"

if FAKE_GS_RELEASE_FILE=$test_dir/invalid-release \
    FAKE_GS_BARRIER_ATTEMPTS=invalid \
    "$fake_gs" "-sOutputFile=$test_dir/invalid-output.pdf" \
    >"$test_dir/invalid.stdout" 2>"$test_dir/invalid.stderr"
then
    printf '%s\n' 'expected invalid barrier attempts to be refused' >&2
    exit 1
fi
grep -q 'must be a positive integer' "$test_dir/invalid.stderr"

printf '%s\n' 'concurrent logging fixture tests passed'
