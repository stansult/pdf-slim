#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-logging.XXXXXX")

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/cli" "$test_dir/bin"
cp "$project_dir/pdf-slim.sh" "$test_dir/cli/pdf-slim.sh"
chmod +x "$test_dir/cli/pdf-slim.sh"
ln -s "$project_dir/tests/fake-gs.sh" "$test_dir/bin/gs"
export PDF_SLIM_STATE_DIR=$test_dir/state

source_pdf=$test_dir/source.pdf
log_file=$PDF_SLIM_STATE_DIR/processed_pdfs.log
printf '%1000s\n' '%PDF-1.7 logging source' >"$source_pdf"

FAKE_GS_MODE=success PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace -i "$source_pdf" >/dev/null
[[ -f $log_file && ! -L $log_file ]]
[[ $(stat -f '%Lp' "$log_file") == 600 ]]
[[ $(stat -f '%Lp' "$PDF_SLIM_STATE_DIR") == 700 ]]

exec 3<"$log_file"
IFS= read -r -d '' header <&3
IFS= read -r -d '' record_path <&3
IFS= read -r -d '' record_size <&3
IFS= read -r -d '' record_mtime <&3
IFS= read -r -d '' record_signature <&3
IFS= read -r -d '' record_outcome <&3
IFS= read -r -d '' record_timestamp <&3
IFS= read -r -d '' record_artifact <&3
exec 3<&-
[[ $header == pdf-slim-log-v2 ]]
[[ $record_path == "$(realpath "$source_pdf")" ]]
[[ $record_size == "$(stat -f '%z' "$source_pdf")" ]]
[[ $record_mtime == "$(stat -f '%m' "$source_pdf")" ]]
[[ $record_signature == *'quality=preserve;'* ]]
[[ $record_outcome == replaced ]]
[[ $record_timestamp =~ ^[0-9]+$ ]]
[[ -z $record_artifact ]]

log_hash=$(shasum -a 256 "$log_file")
FAKE_GS_MODE=failure PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace -i "$source_pdf" >"$test_dir/skip-output"
[[ $(shasum -a 256 "$log_file") == "$log_hash" ]]
grep -q 'skipped unchanged file recorded as processed' "$test_dir/skip-output"

if FAKE_GS_MODE=failure PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --quality balanced --replace \
    -i "$source_pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected a different processing policy to bypass the log' >&2
    exit 1
fi
[[ $(shasum -a 256 "$log_file") == "$log_hash" ]]

dd if=/dev/zero bs=64 count=1 >>"$source_pdf" 2>/dev/null
changed_hash=$(shasum -a 256 "$source_pdf")
if FAKE_GS_MODE=partial-failure PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace -i "$source_pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected changed file conversion to be attempted and fail' >&2
    exit 1
fi
[[ $(shasum -a 256 "$source_pdf") == "$changed_hash" ]]
[[ $(shasum -a 256 "$log_file") == "$log_hash" ]]

if FAKE_GS_MODE=partial-failure PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace --reprocess \
    -i "$source_pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected forced conversion failure' >&2
    exit 1
fi
[[ $(shasum -a 256 "$log_file") == "$log_hash" ]]

FAKE_GS_MODE=success PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace -i "$source_pdf" >/dev/null
record_count=0
exec 3<"$log_file"
IFS= read -r -d '' header <&3
while IFS= read -r -d '' record_path <&3; do
    IFS= read -r -d '' record_size <&3
    IFS= read -r -d '' record_mtime <&3
    IFS= read -r -d '' record_signature <&3
    IFS= read -r -d '' record_outcome <&3
    IFS= read -r -d '' record_timestamp <&3
    IFS= read -r -d '' record_artifact <&3
    ((record_count += 1))
done
exec 3<&-
[[ $record_count -eq 2 ]]

outcome_state=$test_dir/outcome-state
outcome_log=$outcome_state/processed_pdfs.log
tiny_source=$test_dir/tiny.pdf
printf '%s\n' '%PDF' >"$tiny_source"
PDF_SLIM_STATE_DIR=$outcome_state FAKE_GS_MODE=success PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace -i "$tiny_source" >/dev/null
exec 3<"$outcome_log"
IFS= read -r -d '' header <&3
IFS= read -r -d '' record_path <&3
IFS= read -r -d '' record_size <&3
IFS= read -r -d '' record_mtime <&3
IFS= read -r -d '' record_signature <&3
IFS= read -r -d '' record_outcome <&3
IFS= read -r -d '' record_timestamp <&3
IFS= read -r -d '' record_artifact <&3
exec 3<&-
[[ $record_outcome == kept-not-smaller ]]

printf '%s' 'legacy-format-data' >"$log_file"
malformed_source=$test_dir/malformed.pdf
printf '%1000s\n' '%PDF-1.7 malformed log source' >"$malformed_source"
malformed_hash=$(shasum -a 256 "$malformed_source")
if FAKE_GS_MODE=success PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace \
    -i "$malformed_source" >/dev/null 2>&1; then
    printf '%s\n' 'expected malformed log to be refused' >&2
    exit 1
fi
[[ $(shasum -a 256 "$malformed_source") == "$malformed_hash" ]]
[[ $(<"$log_file") == legacy-format-data ]]

printf '%s\0%s\0' pdf-slim-log-v2 incomplete-record >"$log_file"
incomplete_log_hash=$(shasum -a 256 "$log_file")
if FAKE_GS_MODE=success PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace --reprocess \
    -i "$malformed_source" >/dev/null 2>&1; then
    printf '%s\n' 'expected an incomplete version-2 log to be refused' >&2
    exit 1
fi
[[ $(shasum -a 256 "$log_file") == "$incomplete_log_hash" ]]

v1_state=$test_dir/v1-state
v1_log=$v1_state/processed_pdfs.log
mkdir -p "$v1_state"
printf '%s\0%s\0%s\0%s\0' pdf-slim-log-v1 \
    "$(realpath "$malformed_source")" "$(stat -f '%z' "$malformed_source")" \
    "$(stat -f '%m' "$malformed_source")" >"$v1_log"
PDF_SLIM_STATE_DIR=$v1_state FAKE_GS_MODE=failure PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --quality small --replace \
    -i "$malformed_source" >"$test_dir/v1-output"
grep -q 'migrated replacement history' "$test_dir/v1-output"
grep -q 'skipped unchanged file recorded as processed' "$test_dir/v1-output"
exec 3<"$v1_log"
IFS= read -r -d '' header <&3
IFS= read -r -d '' record_path <&3
IFS= read -r -d '' record_size <&3
IFS= read -r -d '' record_mtime <&3
IFS= read -r -d '' record_signature <&3
IFS= read -r -d '' record_outcome <&3
IFS= read -r -d '' record_timestamp <&3
IFS= read -r -d '' record_artifact <&3
exec 3<&-
[[ $header == pdf-slim-log-v2 ]]
[[ $record_signature == '*' ]]
[[ $record_outcome == v1-import ]]
[[ -z $record_timestamp && -z $record_artifact ]]

relocation_cli=$test_dir/relocation-cli
relocation_state=$test_dir/relocation-state
mkdir -p "$relocation_cli"
cp "$project_dir/pdf-slim.sh" "$relocation_cli/pdf-slim.sh"
chmod +x "$relocation_cli/pdf-slim.sh"
printf '%s\0%s\0%s\0%s\0' pdf-slim-log-v1 \
    "$(realpath "$malformed_source")" "$(stat -f '%z' "$malformed_source")" \
    "$(stat -f '%m' "$malformed_source")" \
    >"$relocation_cli/processed_pdfs.log"
PDF_SLIM_STATE_DIR=$relocation_state FAKE_GS_MODE=failure \
    PATH="$test_dir/bin:$PATH" "$relocation_cli/pdf-slim.sh" \
    --replace -i "$malformed_source" >"$test_dir/relocation-output"
[[ -f $relocation_state/processed_pdfs.log ]]
grep -q 'migrated replacement history' "$test_dir/relocation-output"
grep -q 'skipped unchanged file recorded as processed' \
    "$test_dir/relocation-output"
exec 3<"$relocation_state/processed_pdfs.log"
IFS= read -r -d '' header <&3
exec 3<&-
[[ $header == pdf-slim-log-v2 ]]

printf '%s\n' 'logging tests passed'
