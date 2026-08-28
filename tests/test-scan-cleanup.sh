#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-scan-test.XXXXXX")

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

for command_name in gs magick pdfinfo pdfimages pdftotext pdfdetach pdftocairo; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'scan cleanup test requires %s\n' "$command_name" >&2
        exit 1
    }
done
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || {
    printf '%s\n' 'scan cleanup test requires GNU timeout or gtimeout' >&2
    exit 1
}

scan_png=$test_dir/scan.png
scan_pdf=$test_dir/scan.pdf
magick -size 600x800 xc:'#dddddd' \
    -fill '#222222' -draw 'rectangle 70,100 530,115 rectangle 70,180 530,190' \
    -stroke '#2355aa' -strokewidth 5 -draw 'line 90,260 500,330' \
    "$scan_png"
magick -units PixelsPerInch -density 100 "$scan_png" -compress JPEG "$scan_pdf"

source_size=$(pdfinfo "$scan_pdf" | awk -F: \
    '$1 == "Page size" { sub(/^[[:space:]]+/, "", $2); print $2; exit }')

for cleanup_mode in gentle standard strong; do
    output_pdf=$test_dir/$cleanup_mode.pdf
    "$project_dir/pdf-slim.sh" --input "$scan_pdf" --output "$output_pdf" \
        --clean-scan "$cleanup_mode" --preserve-metadata none >/dev/null
    [[ -s $output_pdf ]]
    gs -q -dBATCH -dNOPAUSE -sDEVICE=nullpage -f "$output_pdf"
    output_size=$(pdfinfo "$output_pdf" | awk -F: \
        '$1 == "Page size" { sub(/^[[:space:]]+/, "", $2); print $2; exit }')
    [[ $output_size == "$source_size" ]]
    pdfimages -list "$output_pdf" | awk \
        '$1 == 1 && $2 == 0 && $3 == "image" && $9 == "jpeg" { found = 1 }
        END { exit !found }'
done

detailed_pdf=$test_dir/detailed.pdf
"$project_dir/pdf-slim.sh" --input "$scan_pdf" --output "$detailed_pdf" \
    --clean-scan standard --max-dpi 72 --jpeg-recompress 0.15 \
    --preserve-metadata none >/dev/null
pdfimages -list "$detailed_pdf" | awk \
    '$1 == 1 && $3 == "image" && $13 <= 72 && $14 <= 72 { found = 1 }
    END { exit !found }'

lossless_pdf=$test_dir/lossless.pdf
"$project_dir/pdf-slim.sh" --input "$scan_pdf" --output "$lossless_pdf" \
    --clean-scan gentle --quality preserve --preserve-metadata none >/dev/null
pdfimages -list "$lossless_pdf" | awk \
    '$1 == 1 && $3 == "image" && $9 == "image" { found = 1 }
    END { exit !found }'

multi_pdf=$test_dir/multi.pdf
multi_output=$test_dir/multi-cleaned.pdf
magick -units PixelsPerInch -density 100 "$scan_png" "$scan_png" \
    -compress JPEG "$multi_pdf"
"$project_dir/pdf-slim.sh" --input "$multi_pdf" --output "$multi_output" \
    --clean-scan standard --grayscale --preserve-metadata none >/dev/null
[[ $(pdfinfo "$multi_output" | awk -F: \
    '$1 == "Pages" { sub(/^[[:space:]]+/, "", $2); print $2; exit }') -eq 2 ]]
pdfimages -list "$multi_output" | awk \
    '$1 ~ /^[12]$/ && $3 == "image" && $6 == "gray" { pages[$1] = 1 }
    END { exit !(pages[1] && pages[2]) }'

vector_ps=$test_dir/vector.ps
vector_pdf=$test_dir/vector.pdf
vector_output=$test_dir/vector-cleaned.pdf
printf '%s\n' \
    '%!PS' \
    '/Helvetica findfont 18 scalefont setfont' \
    '72 720 moveto (searchable text must be refused) show' \
    'showpage' >"$vector_ps"
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite "-sOutputFile=$vector_pdf" \
    -f "$vector_ps"
if "$project_dir/pdf-slim.sh" --input "$vector_pdf" --output "$vector_output" \
    --clean-scan standard >"$test_dir/vector.out" 2>"$test_dir/vector.err"; then
    printf '%s\n' 'expected scan cleanup to refuse a vector/text PDF' >&2
    exit 1
fi
[[ ! -e $vector_output ]]
grep -Eq 'searchable text|exactly one image|visible text or vector content' \
    "$test_dir/vector.err"

batch_output=$test_dir/batch
if "$project_dir/pdf-slim.sh" --input "$scan_pdf" --input "$vector_pdf" \
    --output-dir "$batch_output" --clean-scan standard \
    --preserve-metadata none >"$test_dir/batch.out" 2>"$test_dir/batch.err"; then
    printf '%s\n' 'expected a mixed scan/non-scan batch to report failure' >&2
    exit 1
fi
[[ -s $batch_output/scan.pdf ]]
[[ ! -e $batch_output/vector.pdf ]]

printf '%s\n' 'scan cleanup tests passed'
