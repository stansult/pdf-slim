#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)

if [[ ${PDF_SLIM_METRICS_HELPER:-0} == 1 ]]; then
    PDF_SLIM_TESTING=1
    : "$PDF_SLIM_TESTING"
    # shellcheck source=../pdf-slim.sh
    # shellcheck disable=SC1091
    source "$project_dir/pdf-slim.sh"
    append_performance_record "$PERFORMANCE_TEST_RECORD"
    exit
fi

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-metrics-test.XXXXXX")
helper_one=''
helper_two=''

cleanup() {
    local pid
    for pid in "$helper_one" "$helper_two"; do
        if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

PDF_SLIM_TESTING=1
: "$PDF_SLIM_TESTING"
# shellcheck source=../pdf-slim.sh
# shellcheck disable=SC1091
source "$project_dir/pdf-slim.sh"

make_record() {
    local marker=$1 field record=''
    for (( field = 1; field <= 34; field += 1 )); do
        if [[ -n $record ]]; then
            record=$record$'\t'
        fi
        record=$record${marker}-${field}
    done
    printf '%s\n' "$record"
}

concurrent_state=$test_dir/concurrent-state
record_one=$(make_record one)
record_two=$(make_record two)
mkdir -p "$concurrent_state/performance.tsv.lock"
PDF_SLIM_STATE_DIR=$concurrent_state PDF_SLIM_METRICS_HELPER=1 \
PERFORMANCE_TEST_RECORD=$record_one "$0" &
helper_one=$!
PDF_SLIM_STATE_DIR=$concurrent_state PDF_SLIM_METRICS_HELPER=1 \
PERFORMANCE_TEST_RECORD=$record_two "$0" &
helper_two=$!
sleep 0.2
kill -0 "$helper_one" 2>/dev/null
kill -0 "$helper_two" 2>/dev/null
rmdir "$concurrent_state/performance.tsv.lock"
wait "$helper_one"
helper_one=''
wait "$helper_two"
helper_two=''
metrics_file=$concurrent_state/performance.tsv
[[ $(wc -l <"$metrics_file" | tr -d ' ') -eq 3 ]]
[[ $(grep -Fxc -- "$record_one" "$metrics_file") -eq 1 ]]
[[ $(grep -Fxc -- "$record_two" "$metrics_file") -eq 1 ]]
[[ $(stat -f '%Lp' "$concurrent_state") == 700 ]]
[[ $(stat -f '%Lp' "$metrics_file") == 600 ]]
[[ ! -e $metrics_file.lock ]]

# A malformed existing file is never overwritten or appended.
malformed_state=$test_dir/malformed-state
mkdir "$malformed_state"
printf '%s\n' 'unknown-format' >"$malformed_state/performance.tsv"
malformed_hash=$(shasum -a 256 "$malformed_state/performance.tsv")
if PDF_SLIM_STATE_DIR=$malformed_state \
    append_performance_record "$record_one"; then
    printf '%s\n' 'expected malformed metrics file to be refused' >&2
    exit 1
fi
[[ $(shasum -a 256 "$malformed_state/performance.tsv") == "$malformed_hash" ]]

# Product success and failure status are preserved even when metrics storage is
# unavailable. Repeated failures produce only one warning per invocation.
process_source_core() {
    return "${FAKE_PROCESS_STATUS:-0}"
}

source_pdf=$test_dir/private-name.pdf
printf '%s\n' '%PDF-1.7 metrics source' >"$source_pdf"
quality=balanced
max_dpi=''
jpeg_recompress=''
grayscale=0
clean_scan=standard
jobs=auto
: "$quality" "$max_dpi" "$jpeg_recompress" "$grayscale" "$jobs"
detect_metrics_machine
blocked_state=$test_dir/not-a-directory
printf '%s\n' blocked >"$blocked_state"
PDF_SLIM_STATE_DIR=$blocked_state process_source "$source_pdf" source.pdf \
    "$test_dir/output.pdf" pdf 2>"$test_dir/warnings.err"
PDF_SLIM_STATE_DIR=$blocked_state process_source "$source_pdf" source.pdf \
    "$test_dir/output-2.pdf" pdf 2>>"$test_dir/warnings.err"
[[ $(grep -c 'could not record scan-clean performance metrics' \
    "$test_dir/warnings.err") -eq 1 ]]

failure_state=$test_dir/failure-state
METRICS_WARNING_EMITTED=0
: "$METRICS_WARNING_EMITTED"
if PDF_SLIM_STATE_DIR=$failure_state FAKE_PROCESS_STATUS=7 \
    process_source "$source_pdf" source.pdf "$test_dir/failure.pdf" pdf; then
    printf '%s\n' 'expected the stubbed product failure to be preserved' >&2
    exit 1
fi
failure_metrics=$failure_state/performance.tsv
awk -F '\t' 'NR == 2 { exit !(NF == 34 && $5 == "failed" && $6 == "setup" && $11 == "-") }' \
    "$failure_metrics"
if grep -Fq -- "$source_pdf" "$failure_metrics"; then
    printf '%s\n' 'metrics unexpectedly contain the private source path' >&2
    exit 1
fi

# Non-scan PDF work and raster-image scan cleanup do not create concurrency
# records.
excluded_state=$test_dir/excluded-state
clean_scan=''
PDF_SLIM_STATE_DIR=$excluded_state process_source "$source_pdf" source.pdf \
    "$test_dir/ordinary.pdf" pdf
clean_scan=standard
: "$clean_scan"
PDF_SLIM_STATE_DIR=$excluded_state process_source "$source_pdf" source.png \
    "$test_dir/image.pdf" image
[[ ! -e $excluded_state ]]

printf '%s\n' 'performance metrics tests passed'
