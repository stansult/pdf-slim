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

source_pdf=$test_dir/source.pdf
log_file=$test_dir/cli/processed_pdfs.log
printf '%1000s\n' '%PDF-1.7 logging source' >"$source_pdf"

FAKE_GS_MODE=success PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace "$source_pdf" >/dev/null
[[ -f $log_file && ! -L $log_file ]]
[[ $(stat -f '%Lp' "$log_file") == 600 ]]

exec 3<"$log_file"
IFS= read -r -d '' header <&3
IFS= read -r -d '' record_path <&3
IFS= read -r -d '' record_size <&3
IFS= read -r -d '' record_mtime <&3
exec 3<&-
[[ $header == pdf-slim-log-v1 ]]
[[ $record_path == "$(realpath "$source_pdf")" ]]
[[ $record_size == "$(stat -f '%z' "$source_pdf")" ]]
[[ $record_mtime == "$(stat -f '%m' "$source_pdf")" ]]

log_hash=$(shasum -a 256 "$log_file")
FAKE_GS_MODE=failure PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace "$source_pdf" >"$test_dir/skip-output"
[[ $(shasum -a 256 "$log_file") == "$log_hash" ]]
grep -q 'skipped unchanged file recorded as processed' "$test_dir/skip-output"

dd if=/dev/zero bs=64 count=1 >>"$source_pdf" 2>/dev/null
changed_hash=$(shasum -a 256 "$source_pdf")
if FAKE_GS_MODE=partial-failure PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace "$source_pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected changed file conversion to be attempted and fail' >&2
    exit 1
fi
[[ $(shasum -a 256 "$source_pdf") == "$changed_hash" ]]
[[ $(shasum -a 256 "$log_file") == "$log_hash" ]]

if FAKE_GS_MODE=partial-failure PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace --force "$source_pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected forced conversion failure' >&2
    exit 1
fi
[[ $(shasum -a 256 "$log_file") == "$log_hash" ]]

FAKE_GS_MODE=success PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace "$source_pdf" >/dev/null
record_count=0
exec 3<"$log_file"
IFS= read -r -d '' header <&3
while IFS= read -r -d '' record_path <&3; do
    IFS= read -r -d '' record_size <&3
    IFS= read -r -d '' record_mtime <&3
    ((record_count += 1))
done
exec 3<&-
[[ $record_count -eq 2 ]]

printf '%s' 'legacy-format-data' >"$log_file"
malformed_source=$test_dir/malformed.pdf
printf '%1000s\n' '%PDF-1.7 malformed log source' >"$malformed_source"
malformed_hash=$(shasum -a 256 "$malformed_source")
if FAKE_GS_MODE=success PATH="$test_dir/bin:$PATH" \
    "$test_dir/cli/pdf-slim.sh" --replace "$malformed_source" >/dev/null 2>&1; then
    printf '%s\n' 'expected malformed log to be refused' >&2
    exit 1
fi
[[ $(shasum -a 256 "$malformed_source") == "$malformed_hash" ]]
[[ $(<"$log_file") == legacy-format-data ]]

printf '%s\n' 'logging tests passed'
