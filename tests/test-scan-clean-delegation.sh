#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-delegation.XXXXXX")

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

for command_name in gs magick pdfinfo pdfimages pdftotext pdfdetach pdftocairo; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'delegation test requires %s\n' "$command_name" >&2
        exit 1
    }
done

mkdir "$test_dir/sibling" "$test_dir/path-bin" "$test_dir/tmp"
cp "$project_dir/pdf-slim.sh" "$test_dir/sibling/pdf-slim.sh"
cp "$project_dir/tests/fake-scan-clean.sh" "$test_dir/sibling/scan-clean.sh"
cp "$project_dir/tests/fake-scan-clean.sh" "$test_dir/path-bin/scan-clean.sh"
chmod +x "$test_dir/sibling/pdf-slim.sh" \
    "$test_dir/sibling/scan-clean.sh" "$test_dir/path-bin/scan-clean.sh"

PDF_SLIM_TESTING=1
: "$PDF_SLIM_TESTING" # Read by the sourced script.
# shellcheck source=../pdf-slim.sh
# project_dir is resolved to an absolute path at runtime.
# shellcheck disable=SC1091
source "$project_dir/pdf-slim.sh"

resolved=$(PATH="$test_dir/path-bin:$PATH" \
    find_scan_clean_command "$test_dir/sibling/pdf-slim.sh")
[[ $resolved == "$(realpath -- "$test_dir/sibling/scan-clean.sh")" ]]
mv "$test_dir/sibling/scan-clean.sh" "$test_dir/sibling/scan-clean.saved"
resolved=$(PATH="$test_dir/path-bin:$PATH" \
    find_scan_clean_command "$test_dir/sibling/pdf-slim.sh")
[[ $resolved == "$(realpath -- "$test_dir/path-bin/scan-clean.sh")" ]]
if PATH=/usr/bin:/bin find_scan_clean_command \
    "$test_dir/sibling/pdf-slim.sh" >/dev/null 2>&1; then
    printf '%s\n' 'expected scan-clean discovery without sibling or PATH command to fail' >&2
    exit 1
fi
mv "$test_dir/sibling/scan-clean.saved" "$test_dir/sibling/scan-clean.sh"

scan_png=$test_dir/scan.png
scan_pdf=$test_dir/scan.pdf
output_pdf=$test_dir/cleaned.pdf
args_file=$test_dir/scan-clean-args
magick -size 300x400 xc:'#dddddd' -fill '#222222' \
    -draw 'rectangle 35,50 265,58 rectangle 35,90 265,96' "$scan_png"
magick -units PixelsPerInch -density 100 "$scan_png" -compress JPEG "$scan_pdf"

FAKE_SCAN_CLEAN_ARGS_FILE=$args_file \
PATH="$test_dir/path-bin:$PATH" \
    "$test_dir/sibling/pdf-slim.sh" --input "$scan_pdf" \
    --output "$output_pdf" --clean-scan strong --timeout 7s \
    --preserve-metadata none >/dev/null
[[ -s $output_pdf ]]
gs -q -dBATCH -dNOPAUSE -sDEVICE=nullpage -f "$output_pdf"
[[ $(grep -c '^BEGIN$' "$args_file") -eq 1 ]]
awk '$0 == "--mode" { getline; found = ($0 == "strong") }
    END { exit !found }' "$args_file"
awk '$0 == "--timeout" { getline; found = ($0 == "7s") }
    END { exit !found }' "$args_file"
grep -Fx -- '--strip-metadata' "$args_file" >/dev/null
awk '$0 == "--input" { getline; found = ($0 ~ /rendered\/page-1[.]png$/) }
    END { exit !found }' "$args_file"
awk '$0 == "--output" { getline; found = ($0 ~ /cleaned\/page-1[.]png$/) }
    END { exit !found }' "$args_file"

failure_output=$test_dir/failure.pdf
if FAKE_SCAN_CLEAN_MODE=failure PATH="$test_dir/path-bin:$PATH" \
    "$test_dir/sibling/pdf-slim.sh" --input "$scan_pdf" \
    --output "$failure_output" --clean-scan gentle \
    --preserve-metadata none >/dev/null 2>"$test_dir/failure.err"; then
    printf '%s\n' 'expected delegated scan cleanup failure' >&2
    exit 1
fi
[[ ! -e $failure_output ]]
grep -q 'scan contrast cleanup failed with status 9' "$test_dir/failure.err"
grep -q 'fake-scan-clean: deliberate failure' "$test_dir/failure.err"

timeout_output=$test_dir/timeout.pdf
if TMPDIR="$test_dir/tmp" FAKE_SCAN_CLEAN_MODE=sleep \
    PATH="$test_dir/path-bin:$PATH" \
    "$test_dir/sibling/pdf-slim.sh" --input "$scan_pdf" \
    --output "$timeout_output" --clean-scan standard --timeout 1s \
    --preserve-metadata none >/dev/null 2>"$test_dir/timeout.err"; then
    printf '%s\n' 'expected delegated scan cleanup timeout' >&2
    exit 1
fi
[[ ! -e $timeout_output ]]
grep -q 'scan contrast cleanup timed out after 1s' "$test_dir/timeout.err"
if find "$test_dir/tmp" -name 'pdf-slim-scan.*' -print | grep .; then
    printf '%s\n' 'delegated cleanup left a PDF scan temporary directory' >&2
    exit 1
fi

mkdir "$test_dir/fallback"
cp "$project_dir/pdf-slim.sh" "$test_dir/fallback/pdf-slim.sh"
chmod +x "$test_dir/fallback/pdf-slim.sh"
fallback_output=$test_dir/fallback.pdf
FAKE_SCAN_CLEAN_ARGS_FILE=$test_dir/fallback-args \
PATH="$test_dir/path-bin:$PATH" \
    "$test_dir/fallback/pdf-slim.sh" --input "$scan_pdf" \
    --output "$fallback_output" --clean-scan standard \
    --preserve-metadata none >/dev/null
[[ -s $fallback_output ]]
grep -Fx -- 'standard' "$test_dir/fallback-args" >/dev/null

missing_output=$test_dir/missing.pdf
if PATH=/usr/local/bin:/usr/bin:/bin \
    "$test_dir/fallback/pdf-slim.sh" --input "$scan_pdf" \
    --output "$missing_output" --clean-scan standard \
    --preserve-metadata none >/dev/null 2>"$test_dir/missing.err"; then
    printf '%s\n' 'expected missing scan-clean dependency to fail' >&2
    exit 1
fi
[[ ! -e $missing_output ]]
grep -q 'no executable sibling or PATH command was found' \
    "$test_dir/missing.err"

printf '%s\n' 'scan-clean delegation tests passed'
