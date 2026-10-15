#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-inspection.XXXXXX")
bin_dir=$test_dir/bin

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir "$bin_dir"
for command_name in gs magick pdfinfo pdfimages pdftotext pdfdetach; do
    ln -s "$project_dir/tests/fake-scan-inspector.sh" \
        "$bin_dir/$command_name"
done

timeout_command=$(command -v timeout || command -v gtimeout)
source_pdf=$test_dir/source.pdf
printf '%s\n' '%PDF-1.7 inspection fixture' >"$source_pdf"

# Validate the command double's baseline contract independently.
"$bin_dir/pdfinfo" "$source_pdf" | grep -q '^Pages: 1$'
"$bin_dir/pdfinfo" -f 1 -l 1 -box "$source_pdf" | \
    grep -q '^Page 1 size: 612 x 792 pts$'
"$bin_dir/pdfimages" -list "$source_pdf" | awk \
    '$1 == 1 && $3 == "image" && $13 == 300 && $14 == 300 { found = 1 }
    END { exit !found }'
fixture_residual=$test_dir/fixture-0001.png
"$bin_dir/gs" "-sOutputFile=$test_dir/fixture-%04d.png" -f "$source_pdf"
[[ -s $fixture_residual ]]
[[ $("$bin_dir/magick" "$fixture_residual" -format '%[fx:minima]' info:) == 1 ]]

# Validate every soft-mask fixture independently of product behavior.
FAKE_SCAN_INSPECTION_MODE=smask-valid "$bin_dir/pdfimages" -list \
    "$source_pdf" | awk '
    $3 == "image" { image += 1; image_key = $11 ":" $12 ":" $4 ":" $5 ":" $13 ":" $14 }
    $3 == "smask" { smask += 1; smask_key = $11 ":" $12 ":" $4 ":" $5 ":" $13 ":" $14; valid = ($6 == "gray" && $7 == 1) }
    END { exit !(image == 1 && smask == 1 && image_key == smask_key && valid) }'
FAKE_SCAN_INSPECTION_MODE=smask-orphan "$bin_dir/pdfimages" -list \
    "$source_pdf" | awk '$3 == "image" { image += 1 } $3 == "smask" { smask += 1 } END { exit !(image == 0 && smask == 1) }'
FAKE_SCAN_INSPECTION_MODE=smask-object "$bin_dir/pdfimages" -list \
    "$source_pdf" | awk '$3 == "image" { object = $11 ":" $12 } $3 == "smask" { mismatch = (object != $11 ":" $12) } END { exit !mismatch }'
FAKE_SCAN_INSPECTION_MODE=smask-dimensions "$bin_dir/pdfimages" -list \
    "$source_pdf" | awk '$3 == "image" { dimensions = $4 "x" $5 } $3 == "smask" { mismatch = (dimensions != $4 "x" $5) } END { exit !mismatch }'
FAKE_SCAN_INSPECTION_MODE=smask-dpi "$bin_dir/pdfimages" -list \
    "$source_pdf" | awk '$3 == "image" { dpi = $13 "x" $14 } $3 == "smask" { mismatch = (dpi != $13 "x" $14) } END { exit !mismatch }'
FAKE_SCAN_INSPECTION_MODE=smask-color "$bin_dir/pdfimages" -list \
    "$source_pdf" | awk '$3 == "smask" { invalid = ($6 != "gray" || $7 != 1) } END { exit !invalid }'
FAKE_SCAN_INSPECTION_MODE=smask-two "$bin_dir/pdfimages" -list \
    "$source_pdf" | awk '$3 == "smask" { smask += 1 } END { exit !(smask == 2) }'

PDF_SLIM_TESTING=1
: "$PDF_SLIM_TESTING"
# shellcheck source=../pdf-slim.sh
# shellcheck disable=SC1091
source "$project_dir/pdf-slim.sh"

run_inspection() {
    local scan_directory=$1

    inspect_scan_pdf "$source_pdf" "$scan_directory" "$timeout_command" 1s \
        "$bin_dir/gs" "$bin_dir/magick" "$bin_dir/pdfinfo" \
        "$bin_dir/pdfimages" "$bin_dir/pdftotext" "$bin_dir/pdfdetach"
}

valid_directory=$test_dir/valid
mkdir "$valid_directory"
FAKE_SCAN_INSPECTION_MODE=valid
export FAKE_SCAN_INSPECTION_MODE
run_inspection "$valid_directory"
[[ $SCAN_PAGE_COUNT -eq 1 ]]
[[ ${SCAN_PAGE_WIDTH[1]} == 612 ]]
[[ ${SCAN_PAGE_HEIGHT[1]} == 792 ]]
[[ ${SCAN_X_DPI[1]} == 300 ]]
[[ ${SCAN_Y_DPI[1]} == 300 ]]

smask_directory=$test_dir/smask-valid
mkdir "$smask_directory"
FAKE_SCAN_INSPECTION_MODE=smask-valid
export FAKE_SCAN_INSPECTION_MODE
run_inspection "$smask_directory"
[[ $SCAN_PAGE_COUNT -eq 1 ]]
[[ ${SCAN_X_DPI[1]} == 300 ]]
[[ ${SCAN_Y_DPI[1]} == 300 ]]

run_refusal() {
    local case_mode=$1
    local expected=$2
    local scan_directory=$test_dir/$case_mode

    mkdir "$scan_directory"
    FAKE_SCAN_INSPECTION_MODE=$case_mode
    export FAKE_SCAN_INSPECTION_MODE
    if run_inspection "$scan_directory" >"$scan_directory/out" \
        2>"$scan_directory/err"; then
        printf 'expected scan inspection mode %s to be refused\n' \
            "$case_mode" >&2
        exit 1
    fi
    grep -q -- "$expected" "$scan_directory/err"
}

run_refusal bad-pages 'positive page count'
run_refusal encrypted 'unencrypted PDF'
run_refusal form 'containing forms'
run_refusal javascript 'containing JavaScript'
run_refusal geometry 'page geometry'
run_refusal text 'searchable text'
run_refusal attachment 'embedded files'
run_refusal link 'containing links'
run_refusal destination 'named destinations'
run_refusal image-zero 'exactly one image on every page'
run_refusal image-mask 'exactly one ordinary image per page'
run_refusal image-dpi 'exactly one ordinary image per page'
run_refusal image-two 'exactly one image on every page'
run_refusal smask-orphan 'exactly one image on every page'
run_refusal smask-object 'soft mask does not match its page image'
run_refusal smask-dimensions 'soft mask does not match its page image'
run_refusal smask-dpi 'soft mask does not match its page image'
run_refusal smask-color 'grayscale, single-component soft mask'
run_refusal smask-two 'at most one associated soft mask'
run_refusal residual 'visible text or vector content'

printf '%s\n' 'scan inspection guard tests passed'
