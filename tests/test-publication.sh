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
: "$PDF_SLIM_TESTING" # Read by the sourced script; do not export to child CLIs.
# shellcheck source=../pdf-slim.sh
# project_dir is resolved to an absolute path at runtime.
# shellcheck disable=SC1091
source "$project_dir/pdf-slim.sh"

timeout_command=$(find_command timeout gtimeout)
gs_command=$project_dir/tests/fake-gs.sh
timeout_duration=1s
grayscale=0
quality=preserve
max_dpi=''
jpeg_recompress=''
metadata_mode=standard
ACTIVE_CANDIDATE=''
ACTIVE_METADATA_REFERENCE=''
# process_source reads these variables through Bash dynamic scope.
: "$timeout_command" "$timeout_duration" "$grayscale" "$quality" "$max_dpi" \
    "$jpeg_recompress" "$metadata_mode" "$ACTIVE_CANDIDATE" \
    "$ACTIVE_METADATA_REFERENCE"

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

mode='file'
exact_pdf=$test_dir/exact.pdf
exact_source_atime=$(stat -f '%a' "$source_pdf")
process_source "$source_pdf" source.pdf "$exact_pdf"
[[ -s $exact_pdf ]]
[[ $(file_mode "$exact_pdf") == 640 ]]
[[ $(stat -f '%a' "$exact_pdf") == "$exact_source_atime" ]]
[[ $(stat -f '%m' "$exact_pdf") == "$source_mtime" ]]

metadata_change_pdf=$test_dir/metadata-change.pdf
metadata_change_output=$test_dir/metadata-change-output.pdf
printf '%1000s\n' '%PDF-1.7 metadata change source' >"$metadata_change_pdf"
metadata_change_hash=$(shasum -a 256 <"$metadata_change_pdf")
metadata_change_size=$(file_size "$metadata_change_pdf")
metadata_change_mtime=$(file_mtime "$metadata_change_pdf")
metadata_change_ctime=$(stat -f '%c' "$metadata_change_pdf")
FAKE_GS_SOURCE_CHANGE=metadata-only
export FAKE_GS_SOURCE_CHANGE
timeout_duration=3s
process_source "$metadata_change_pdf" metadata-change.pdf \
    "$metadata_change_output"
[[ -s $metadata_change_output ]]
[[ $(shasum -a 256 <"$metadata_change_pdf") == "$metadata_change_hash" ]]
[[ $(file_size "$metadata_change_pdf") == "$metadata_change_size" ]]
[[ $(file_mtime "$metadata_change_pdf") == "$metadata_change_mtime" ]]
[[ $(stat -f '%c' "$metadata_change_pdf") != "$metadata_change_ctime" ]]

content_change_pdf=$test_dir/content-change.pdf
content_change_output=$test_dir/content-change-output.pdf
content_change_reference=$test_dir/content-change-reference
printf '%1000s\n' '%PDF-1.7 content change source' >"$content_change_pdf"
touch -r "$content_change_pdf" "$content_change_reference"
content_change_size=$(file_size "$content_change_pdf")
content_change_mtime=$(file_mtime "$content_change_pdf")
content_change_ctime=$(stat -f '%c' "$content_change_pdf")
content_change_hash=$(shasum -a 256 <"$content_change_pdf")
FAKE_GS_SOURCE_CHANGE=content-preserve-stat
FAKE_GS_MTIME_REFERENCE=$content_change_reference
export FAKE_GS_SOURCE_CHANGE FAKE_GS_MTIME_REFERENCE
if process_source "$content_change_pdf" content-change.pdf \
    "$content_change_output"; then
    printf '%s\n' 'expected changed source content to block publication' >&2
    exit 1
fi
[[ ! -e $content_change_output ]]
[[ $(file_size "$content_change_pdf") == "$content_change_size" ]]
[[ $(file_mtime "$content_change_pdf") == "$content_change_mtime" ]]
[[ $(stat -f '%c' "$content_change_pdf") != "$content_change_ctime" ]]
[[ $(shasum -a 256 <"$content_change_pdf") != "$content_change_hash" ]]
unset FAKE_GS_SOURCE_CHANGE FAKE_GS_MTIME_REFERENCE
timeout_duration=1s

mode=replace
metadata_replace_pdf=$test_dir/metadata-replace.pdf
printf '%1000s\n' '%PDF-1.7 metadata replacement source' \
    >"$metadata_replace_pdf"
metadata_replace_size=$(file_size "$metadata_replace_pdf")
FAKE_GS_SOURCE_CHANGE=metadata-only
export FAKE_GS_SOURCE_CHANGE
timeout_duration=3s
process_source "$metadata_replace_pdf" metadata-replace.pdf \
    "$metadata_replace_pdf"
[[ $(file_size "$metadata_replace_pdf") -lt $metadata_replace_size ]]
unset FAKE_GS_SOURCE_CHANGE
timeout_duration=1s

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
    : "$metadata_mode" "$mode"
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
    -i "$interrupt_pdf" >/dev/null 2>&1 &
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

race_pdf=$test_dir/race.pdf
race_destination=$test_dir/race-output.pdf
printf '%1000s\n' '%PDF-1.7 race source' >"$race_pdf"
FAKE_GS_MODE=sleep PATH="$test_dir/bin:$PATH" \
    "$project_dir/pdf-slim.sh" -o "$race_destination" \
    -i "$race_pdf" >/dev/null 2>&1 &
process_id=$!
sleep 0.2
printf '%s\n' 'existing destination' >"$race_destination"
set +o errexit
wait "$process_id"
race_status=$?
set -o errexit
[[ $race_status -eq 1 ]]
[[ $(sed -n '1p' "$race_destination") == 'existing destination' ]]

if find "$test_dir" -name '.pdf-slim.*' -print | grep .; then
    printf '%s\n' 'temporary candidate was not cleaned up' >&2
    exit 1
fi

# Redefine metadata finalization only for this last sourced-function test. The
# first call changes source permissions after copying them; the final replace
# checkpoint must tolerate unchanged bytes and refresh the candidate metadata.
finalize_candidate_metadata() {
    local source=$1
    local candidate=$2
    local source_mode

    source_mode=$(file_mode "$source")
    chmod "$source_mode" "$candidate"
    final_metadata_calls=$((final_metadata_calls + 1))
    if (( final_metadata_calls == 1 )); then
        sleep 1.1
        chmod 600 "$source"
    fi
}

mode=replace
metadata_mode=basic
final_metadata_calls=0
final_checkpoint_pdf=$test_dir/final-checkpoint.pdf
printf '%1000s\n' '%PDF-1.7 final checkpoint source' >"$final_checkpoint_pdf"
chmod 640 "$final_checkpoint_pdf"
FAKE_GS_MODE=success
export FAKE_GS_MODE
process_source "$final_checkpoint_pdf" final-checkpoint.pdf \
    "$final_checkpoint_pdf"
[[ $final_metadata_calls -eq 2 ]]
[[ $(file_mode "$final_checkpoint_pdf") == 600 ]]

printf '%s\n' 'publication tests passed'
