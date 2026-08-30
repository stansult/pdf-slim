#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-image-pdf.XXXXXX")
cli=$project_dir/pdf-slim.sh

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

for command_name in gs magick pdfinfo pdfimages; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'image-to-PDF test requires %s\n' "$command_name" >&2
        exit 1
    }
done

mkdir -p "$test_dir/input/sub"
low_dpi_image=$test_dir/input/phone.jpg
credible_dpi_image=$test_dir/input/scanner.png
magick -size 240x300 -units PixelsPerInch -density 72 xc:'#e3d2ba' \
    -fill '#292321' -draw 'rectangle 25,40 215,50 rectangle 25,85 215,92' \
    -quality 92 "$low_dpi_image"
magick -size 240x300 -units PixelsPerInch -density 200 xc:'#eeeeee' \
    -fill '#222222' -draw 'rectangle 25,40 215,50 rectangle 25,85 215,92' \
    "$credible_dpi_image"
magick -size 40x40 xc:white "$test_dir/input/sub/nested.png"
printf '%s\n' 'not an image' >"$test_dir/input/note.txt"

low_dpi_pdf=$test_dir/phone-cleaned.pdf
"$cli" --input "$low_dpi_image" --output "$low_dpi_pdf" \
    --clean-scan standard --preserve-metadata none >/dev/null
[[ -s $low_dpi_pdf ]]
gs -q -dBATCH -dNOPAUSE -sDEVICE=nullpage -f "$low_dpi_pdf"
pdfinfo "$low_dpi_pdf" | awk -F: \
    '$1 == "Page size" {
        split($2, fields, " ")
        exit !(fields[1] > 57.5 && fields[1] < 57.7 &&
            fields[3] > 71.9 && fields[3] < 72.1)
    }'

credible_dpi_pdf=$test_dir/scanner-cleaned.pdf
"$cli" --input "$credible_dpi_image" --output "$credible_dpi_pdf" \
    --clean-scan gentle --preserve-metadata none >/dev/null
pdfinfo "$credible_dpi_pdf" | awk -F: \
    '$1 == "Page size" {
        split($2, fields, " ")
        exit !(fields[1] > 86.3 && fields[1] < 86.5 &&
            fields[3] > 107.9 && fields[3] < 108.1)
    }'

detailed_pdf=$test_dir/phone-detailed.pdf
"$cli" --input "$low_dpi_image" --output "$detailed_pdf" \
    --clean-scan strong --max-dpi 150 --jpeg-recompress 0.15 \
    --grayscale --preserve-metadata none >/dev/null
pdfimages -list "$detailed_pdf" | awk \
    '$1 == 1 && $3 == "image" && $6 == "gray" && $13 <= 150 && $14 <= 150 {
        found = 1
    }
    END { exit !found }'

batch_output=$test_dir/output
"$cli" --input "$test_dir/input" --output-dir "$batch_output" \
    --clean-scan standard --preserve-metadata none \
    >"$test_dir/batch.out" 2>"$test_dir/batch.err"
[[ -s $batch_output/phone.pdf ]]
[[ -s $batch_output/scanner.pdf ]]
[[ ! -e $batch_output/sub/nested.pdf ]]
grep -q 'skipping non-PDF/non-raster file:' "$test_dir/batch.err"

recursive_output=$test_dir/recursive
"$cli" --input "$test_dir/input" --output-dir "$recursive_output" \
    --recursive --clean-scan standard --preserve-metadata none \
    >/dev/null 2>&1
[[ -s $recursive_output/sub/nested.pdf ]]

mkdir "$test_dir/collision"
cp "$low_dpi_image" "$test_dir/collision/same.jpg"
cp "$credible_dpi_image" "$test_dir/collision/same.png"
if "$cli" --input "$test_dir/collision" \
    --output-dir "$test_dir/collision-output" --clean-scan standard \
    >/dev/null 2>"$test_dir/collision.err"; then
    printf '%s\n' 'expected image-to-PDF destination collision' >&2
    exit 1
fi
grep -q 'destination collision:' "$test_dir/collision.err"
[[ ! -e $test_dir/collision-output ]]

original_hash=$(shasum -a 256 "$low_dpi_image")
if "$cli" --input "$low_dpi_image" --replace --clean-scan standard \
    >/dev/null 2>"$test_dir/replace.err"; then
    printf '%s\n' 'expected image input with --replace to fail' >&2
    exit 1
fi
grep -q -- '--replace cannot be used with raster-image input' \
    "$test_dir/replace.err"
[[ $(shasum -a 256 "$low_dpi_image") == "$original_hash" ]]

if "$cli" --input "$low_dpi_image" --output "$test_dir/no-clean.pdf" \
    >/dev/null 2>"$test_dir/no-clean.err"; then
    printf '%s\n' 'expected image input without --clean-scan to fail' >&2
    exit 1
fi
grep -q 'raster image with --clean-scan' "$test_dir/no-clean.err"
[[ ! -e $test_dir/no-clean.pdf ]]

if "$cli" --input "$low_dpi_image" --output "$test_dir/wrong-extension.jpg" \
    --clean-scan standard >/dev/null 2>"$test_dir/wrong-extension.err"; then
    printf '%s\n' 'expected image input with non-PDF output name to fail' >&2
    exit 1
fi
grep -q 'requires a .pdf output filename' "$test_dir/wrong-extension.err"
[[ ! -e $test_dir/wrong-extension.jpg ]]

magick -size 20x20 xc:white -size 20x20 xc:black "$test_dir/animated.gif"
if "$cli" --input "$test_dir/animated.gif" \
    --output "$test_dir/animated.pdf" --clean-scan standard \
    >/dev/null 2>"$test_dir/animated.err"; then
    printf '%s\n' 'expected animated image input to fail' >&2
    exit 1
fi
grep -q 'supported single-frame raster image' "$test_dir/animated.err"
[[ ! -e $test_dir/animated.pdf ]]

printf '%s\n' 'image-to-PDF tests passed'
