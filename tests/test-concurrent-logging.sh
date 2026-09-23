#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-concurrent-logging.XXXXXX")
fake_gs_pid=''
concurrent_pid_one=''
concurrent_pid_two=''

cleanup() {
    local background_pid
    for background_pid in \
        "$fake_gs_pid" "$concurrent_pid_one" "$concurrent_pid_two"
    do
        if [[ -n $background_pid ]] && kill -0 "$background_pid" 2>/dev/null; then
            kill "$background_pid" 2>/dev/null || true
            wait "$background_pid" 2>/dev/null || true
        fi
    done
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

concurrent_dir=$test_dir/concurrent-new-log
concurrent_bin=$concurrent_dir/bin
concurrent_state=$concurrent_dir/state
concurrent_release=$concurrent_dir/release
concurrent_ready_one=$concurrent_dir/ready-one
concurrent_ready_two=$concurrent_dir/ready-two
source_one=$concurrent_dir/source-one.pdf
source_two=$concurrent_dir/source-two.pdf
log_file=$concurrent_state/processed_pdfs.log
mkdir -p "$concurrent_bin"
ln -s "$fake_gs" "$concurrent_bin/gs"
printf '%1000s\n' '%PDF-1.7 concurrent source one' >"$source_one"
printf '%1200s\n' '%PDF-1.7 concurrent source two' >"$source_two"

PDF_SLIM_STATE_DIR=$concurrent_state \
FAKE_GS_MODE=success \
FAKE_GS_READY_FILE=$concurrent_ready_one \
FAKE_GS_RELEASE_FILE=$concurrent_release \
FAKE_GS_BARRIER_ATTEMPTS=50 \
PATH="$concurrent_bin:$PATH" \
    "$project_dir/pdf-slim.sh" --replace -i "$source_one" \
    >"$concurrent_dir/one.stdout" 2>"$concurrent_dir/one.stderr" &
concurrent_pid_one=$!

PDF_SLIM_STATE_DIR=$concurrent_state \
FAKE_GS_MODE=success \
FAKE_GS_READY_FILE=$concurrent_ready_two \
FAKE_GS_RELEASE_FILE=$concurrent_release \
FAKE_GS_BARRIER_ATTEMPTS=50 \
PATH="$concurrent_bin:$PATH" \
    "$project_dir/pdf-slim.sh" --replace -i "$source_two" \
    >"$concurrent_dir/two.stdout" 2>"$concurrent_dir/two.stderr" &
concurrent_pid_two=$!

ready_attempt=0
while [[ ! -e $concurrent_ready_one || ! -e $concurrent_ready_two ]]; do
    if ! kill -0 "$concurrent_pid_one" 2>/dev/null || \
        ! kill -0 "$concurrent_pid_two" 2>/dev/null
    then
        printf '%s\n' 'a concurrent conversion exited before both were ready' >&2
        exit 1
    fi
    if ((ready_attempt >= 50)); then
        printf '%s\n' 'timed out waiting for concurrent conversions' >&2
        exit 1
    fi
    sleep 0.1
    ((ready_attempt += 1))
done

[[ ! -e $log_file ]]
: >"$concurrent_release"
status_one=0
status_two=0
wait "$concurrent_pid_one" || status_one=$?
concurrent_pid_one=''
wait "$concurrent_pid_two" || status_two=$?
concurrent_pid_two=''
[[ $status_one -eq 0 && $status_two -eq 0 ]]

[[ -f $log_file && ! -L $log_file ]]
[[ $(stat -f '%Lp' "$concurrent_state") == 700 ]]
[[ $(stat -f '%Lp' "$log_file") == 600 ]]
[[ ! -e $log_file.lock ]]
[[ -z $(find "$concurrent_state" -mindepth 1 \
    ! -name processed_pdfs.log -print -quit) ]]

canonical_one=$(realpath "$source_one")
canonical_two=$(realpath "$source_two")
found_one=0
found_two=0
record_count=0
exec 3<"$log_file"
IFS= read -r -d '' header <&3
[[ $header == pdf-slim-log-v2 ]]
while IFS= read -r -d '' record_path <&3; do
    IFS= read -r -d '' record_size <&3
    IFS= read -r -d '' record_mtime <&3
    IFS= read -r -d '' record_signature <&3
    IFS= read -r -d '' record_outcome <&3
    IFS= read -r -d '' record_timestamp <&3
    IFS= read -r -d '' record_artifact <&3
    ((record_count += 1))

    case $record_path in
        "$canonical_one")
            ((found_one += 1))
            [[ $record_size == "$(stat -f '%z' "$source_one")" ]]
            [[ $record_mtime == "$(stat -f '%m' "$source_one")" ]]
            ;;
        "$canonical_two")
            ((found_two += 1))
            [[ $record_size == "$(stat -f '%z' "$source_two")" ]]
            [[ $record_mtime == "$(stat -f '%m' "$source_two")" ]]
            ;;
        *)
            printf 'unexpected concurrent log path: %s\n' "$record_path" >&2
            exit 1
            ;;
    esac
    [[ $record_signature == *'quality=preserve;'* ]]
    [[ $record_outcome == replaced ]]
    [[ $record_timestamp =~ ^[0-9]+$ ]]
    [[ -z $record_artifact ]]
done
exec 3<&-
[[ $record_count -eq 2 ]]
[[ $found_one -eq 1 && $found_two -eq 1 ]]

existing_dir=$test_dir/concurrent-existing-log
existing_state=$existing_dir/state
existing_release=$existing_dir/release
existing_ready_one=$existing_dir/ready-one
existing_ready_two=$existing_dir/ready-two
seed_source=$existing_dir/seed.pdf
append_source_one=$existing_dir/append-one.pdf
append_source_two=$existing_dir/append-two.pdf
existing_log=$existing_state/processed_pdfs.log
mkdir -p "$existing_dir"
printf '%1400s\n' '%PDF-1.7 existing log seed' >"$seed_source"
printf '%1600s\n' '%PDF-1.7 existing log append one' >"$append_source_one"
printf '%1800s\n' '%PDF-1.7 existing log append two' >"$append_source_two"

PDF_SLIM_STATE_DIR=$existing_state \
FAKE_GS_MODE=success \
PATH="$concurrent_bin:$PATH" \
    "$project_dir/pdf-slim.sh" --replace -i "$seed_source" \
    >"$existing_dir/seed.stdout" 2>"$existing_dir/seed.stderr"

exec 3<"$existing_log"
IFS= read -r -d '' seed_header <&3
IFS= read -r -d '' seed_path <&3
IFS= read -r -d '' seed_size <&3
IFS= read -r -d '' seed_mtime <&3
IFS= read -r -d '' seed_signature <&3
IFS= read -r -d '' seed_outcome <&3
IFS= read -r -d '' seed_timestamp <&3
IFS= read -r -d '' seed_artifact <&3
if IFS= read -r -d '' unexpected_seed_record <&3; then
    printf 'unexpected extra seed record: %s\n' "$unexpected_seed_record" >&2
    exit 1
fi
exec 3<&-
[[ $seed_header == pdf-slim-log-v2 ]]
[[ $seed_path == "$(realpath "$seed_source")" ]]
[[ $seed_size == "$(stat -f '%z' "$seed_source")" ]]
[[ $seed_mtime == "$(stat -f '%m' "$seed_source")" ]]
[[ $seed_signature == *'quality=preserve;'* ]]
[[ $seed_outcome == replaced ]]
[[ $seed_timestamp =~ ^[0-9]+$ ]]
[[ -z $seed_artifact ]]
seed_log_hash=$(shasum -a 256 "$existing_log")

PDF_SLIM_STATE_DIR=$existing_state \
FAKE_GS_MODE=success \
FAKE_GS_READY_FILE=$existing_ready_one \
FAKE_GS_RELEASE_FILE=$existing_release \
FAKE_GS_BARRIER_ATTEMPTS=50 \
PATH="$concurrent_bin:$PATH" \
    "$project_dir/pdf-slim.sh" --replace -i "$append_source_one" \
    >"$existing_dir/one.stdout" 2>"$existing_dir/one.stderr" &
concurrent_pid_one=$!

PDF_SLIM_STATE_DIR=$existing_state \
FAKE_GS_MODE=success \
FAKE_GS_READY_FILE=$existing_ready_two \
FAKE_GS_RELEASE_FILE=$existing_release \
FAKE_GS_BARRIER_ATTEMPTS=50 \
PATH="$concurrent_bin:$PATH" \
    "$project_dir/pdf-slim.sh" --replace -i "$append_source_two" \
    >"$existing_dir/two.stdout" 2>"$existing_dir/two.stderr" &
concurrent_pid_two=$!

ready_attempt=0
while [[ ! -e $existing_ready_one || ! -e $existing_ready_two ]]; do
    if ! kill -0 "$concurrent_pid_one" 2>/dev/null || \
        ! kill -0 "$concurrent_pid_two" 2>/dev/null
    then
        printf '%s\n' 'an existing-log append exited before both were ready' >&2
        exit 1
    fi
    if ((ready_attempt >= 50)); then
        printf '%s\n' 'timed out waiting for existing-log appends' >&2
        exit 1
    fi
    sleep 0.1
    ((ready_attempt += 1))
done

[[ $(shasum -a 256 "$existing_log") == "$seed_log_hash" ]]
: >"$existing_release"
status_one=0
status_two=0
wait "$concurrent_pid_one" || status_one=$?
concurrent_pid_one=''
wait "$concurrent_pid_two" || status_two=$?
concurrent_pid_two=''
[[ $status_one -eq 0 && $status_two -eq 0 ]]

[[ -f $existing_log && ! -L $existing_log ]]
[[ $(stat -f '%Lp' "$existing_state") == 700 ]]
[[ $(stat -f '%Lp' "$existing_log") == 600 ]]
[[ ! -e $existing_log.lock ]]
[[ -z $(find "$existing_state" -mindepth 1 \
    ! -name processed_pdfs.log -print -quit) ]]

canonical_seed=$(realpath "$seed_source")
canonical_append_one=$(realpath "$append_source_one")
canonical_append_two=$(realpath "$append_source_two")
found_seed=0
found_append_one=0
found_append_two=0
record_count=0
exec 3<"$existing_log"
IFS= read -r -d '' header <&3
[[ $header == pdf-slim-log-v2 ]]
while IFS= read -r -d '' record_path <&3; do
    IFS= read -r -d '' record_size <&3
    IFS= read -r -d '' record_mtime <&3
    IFS= read -r -d '' record_signature <&3
    IFS= read -r -d '' record_outcome <&3
    IFS= read -r -d '' record_timestamp <&3
    IFS= read -r -d '' record_artifact <&3
    ((record_count += 1))

    case $record_path in
        "$canonical_seed")
            ((found_seed += 1))
            [[ $record_size == "$seed_size" ]]
            [[ $record_mtime == "$seed_mtime" ]]
            [[ $record_signature == "$seed_signature" ]]
            [[ $record_outcome == "$seed_outcome" ]]
            [[ $record_timestamp == "$seed_timestamp" ]]
            [[ $record_artifact == "$seed_artifact" ]]
            ;;
        "$canonical_append_one")
            ((found_append_one += 1))
            [[ $record_size == "$(stat -f '%z' "$append_source_one")" ]]
            [[ $record_mtime == "$(stat -f '%m' "$append_source_one")" ]]
            ;;
        "$canonical_append_two")
            ((found_append_two += 1))
            [[ $record_size == "$(stat -f '%z' "$append_source_two")" ]]
            [[ $record_mtime == "$(stat -f '%m' "$append_source_two")" ]]
            ;;
        *)
            printf 'unexpected existing-log path: %s\n' "$record_path" >&2
            exit 1
            ;;
    esac
    [[ $record_signature == *'quality=preserve;'* ]]
    [[ $record_outcome == replaced ]]
    [[ $record_timestamp =~ ^[0-9]+$ ]]
    [[ -z $record_artifact ]]
done
exec 3<&-
[[ $record_count -eq 3 ]]
[[ $found_seed -eq 1 ]]
[[ $found_append_one -eq 1 && $found_append_two -eq 1 ]]

printf '%s\n' 'concurrent logging tests passed'
