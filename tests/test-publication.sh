#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-publication.XXXXXX")

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

PDF_SLIM_TESTING=1
# shellcheck source=../pdf-slim.sh
source "$project_dir/pdf-slim.sh"

timeout_command=$(find_command timeout gtimeout)
gs_command=$project_dir/tests/fake-gs.sh
timeout_duration=1s
grayscale=0
metadata_mode=standard
ACTIVE_CANDIDATE=''
ACTIVE_METADATA_REFERENCE=''

source_pdf=$test_dir/source.pdf
printf '%1000s\n' '%PDF-1.7 source' >"$source_pdf"
chmod 640 "$source_pdf"
touch -a -t 201901020304 "$source_pdf"
touch -m -t 202001020304 "$source_pdf"
source_atime=$(stat -f '%a' "$source_pdf")
source_mtime=$(stat -f '%m' "$source_pdf")

mode=output
output_dir=$test_dir/output
FAKE_GS_MODE=success
export FAKE_GS_MODE
process_source "$source_pdf" source.pdf "$output_dir/source.pdf"
[[ -s $output_dir/source.pdf ]]
[[ $(file_mode "$output_dir/source.pdf") == 640 ]]
[[ $(stat -f '%a' "$output_dir/source.pdf") == "$source_atime" ]]
[[ $(stat -f '%m' "$output_dir/source.pdf") == "$source_mtime" ]]

mode=replace
replace_pdf=$test_dir/replace.pdf
printf '%1000s\n' '%PDF-1.7 replace source' >"$replace_pdf"
original_size=$(file_size "$replace_pdf")
process_source "$replace_pdf" replace.pdf "$replace_pdf"
[[ $(file_size "$replace_pdf") -lt $original_size ]]

retained_pdf=$test_dir/retained.pdf
printf 'tiny' >"$retained_pdf"
retained_hash=$(shasum -a 256 "$retained_pdf")
process_source "$retained_pdf" retained.pdf "$retained_pdf"
[[ $(shasum -a 256 "$retained_pdf") == "$retained_hash" ]]

failed_pdf=$test_dir/failed.pdf
printf '%1000s\n' '%PDF-1.7 failed source' >"$failed_pdf"
failed_hash=$(shasum -a 256 "$failed_pdf")
FAKE_GS_MODE=partial-failure
export FAKE_GS_MODE
if process_source "$failed_pdf" failed.pdf "$failed_pdf"; then
    printf '%s\n' 'expected partial conversion failure' >&2
    exit 1
fi
[[ $(shasum -a 256 "$failed_pdf") == "$failed_hash" ]]

if [[ $(uname -s) == Darwin ]] && command -v xattr >/dev/null 2>&1; then
    metadata_mode=all
    mode=output
    output_dir=$test_dir/all-output
    all_pdf=$test_dir/all.pdf
    printf '%1000s\n' '%PDF-1.7 all metadata source' >"$all_pdf"
    xattr -w com.example.pdf-slim metadata-test "$all_pdf"
    chmod +a "$USER allow read,write" "$all_pdf"
    FAKE_GS_MODE=success
    export FAKE_GS_MODE
    process_source "$all_pdf" all.pdf "$output_dir/all.pdf"
    [[ $(xattr -p com.example.pdf-slim "$output_dir/all.pdf") == metadata-test ]]
    source_acl=$(ls -lde "$all_pdf")
    output_acl=$(ls -lde "$output_dir/all.pdf")
    source_acl=${source_acl#*$'\n'}
    output_acl=${output_acl#*$'\n'}
    [[ $source_acl == "$output_acl" ]]
fi

mkdir "$test_dir/bin"
ln -s "$gs_command" "$test_dir/bin/gs"
interrupt_pdf=$test_dir/interrupt.pdf
printf '%1000s\n' '%PDF-1.7 interrupt source' >"$interrupt_pdf"
interrupt_hash=$(shasum -a 256 "$interrupt_pdf")
FAKE_GS_MODE=sleep PATH="$test_dir/bin:$PATH" \
    "$project_dir/pdf-slim.sh" --output-dir "$test_dir/interrupt-output" \
    "$interrupt_pdf" >/dev/null 2>&1 &
process_id=$!
sleep 0.2
kill -TERM "$process_id"
set +o errexit
wait "$process_id"
interrupt_status=$?
set -o errexit
[[ $interrupt_status -eq 143 ]]
[[ $(shasum -a 256 "$interrupt_pdf") == "$interrupt_hash" ]]
[[ ! -e $test_dir/interrupt-output/interrupt.pdf ]]

if find "$test_dir" -name '.pdf-slim.*' -print | grep .; then
    printf '%s\n' 'temporary candidate was not cleaned up' >&2
    exit 1
fi

printf '%s\n' 'publication tests passed'
