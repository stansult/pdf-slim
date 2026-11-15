#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-tone-test.XXXXXX")
cli=${PDF_SLIM_CLI:-$project_dir/pdf-slim.sh}
export PDF_SLIM_STATE_DIR=$test_dir/state

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

for command_name in gs magick pdfinfo pdfimages pdftocairo; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'PDF scan tonal test requires %s\n' "$command_name" >&2
        exit 1
    }
done

command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || {
    printf '%s\n' 'PDF scan tonal test requires GNU timeout or gtimeout' >&2
    exit 1
}

region_mean() {
    local image=$1
    local geometry=$2

    magick "$image" -crop "$geometry" +repage -colorspace Gray \
        -format '%[fx:mean]' info:
}

assert_between() {
    local label=$1
    local value=$2
    local minimum=$3
    local maximum=$4

    awk -v label="$label" -v value="$value" -v minimum="$minimum" \
        -v maximum="$maximum" 'BEGIN {
            if (value < minimum || value > maximum) {
                printf "%s: expected %.6f between %.6f and %.6f\n", \
                    label, value, minimum, maximum > "/dev/stderr"
                exit 1
            }
        }'
}

gray_png=$test_dir/gray-paper.png
bright_png=$test_dir/bright-paper.png
source_pdf=$test_dir/source.pdf
output_pdf=$test_dir/cleaned.pdf

for fixture in "$gray_png:#e3e3e3" "$bright_png:#f1f1f1"; do
    destination=${fixture%%:*}
    background=${fixture#*:}
    magick -size 600x800 -units PixelsPerInch -density 100 \
        "xc:$background" \
        -fill '#202020' -draw 'rectangle 100,150 500,200' \
        -fill '#a0a0a0' -stroke '#a0a0a0' -strokewidth 6 \
        -draw 'line 100,500 500,500' "$destination"
done

magick -units PixelsPerInch -density 100 "$gray_png" "$bright_png" \
    -compress JPEG "$source_pdf"

# Independently verify that the assembled fixture is a two-page image-only PDF
# and that PDF encoding retained the intended page tones and faint mark.
[[ $(pdfinfo "$source_pdf" | awk -F: \
    '$1 == "Pages" { sub(/^[[:space:]]+/, "", $2); print $2; exit }') -eq 2 ]]
pdfimages -list "$source_pdf" | awk '
    $1 ~ /^[12]$/ && $3 == "image" { images[$1] += 1 }
    END { exit !(images[1] == 1 && images[2] == 1) }'
pdftocairo -png -r 100 "$source_pdf" "$test_dir/source-render"
for page in 1 2; do
    [[ $(magick identify -quiet -format '%wx%h' \
        "$test_dir/source-render-$page.png") == 600x800 ]]
done

source_gray_background=$(region_mean "$test_dir/source-render-1.png" \
    '40x40+20+20')
source_bright_background=$(region_mean "$test_dir/source-render-2.png" \
    '40x40+20+20')
source_faint_mark=$(region_mean "$test_dir/source-render-1.png" \
    '400x6+100+498')
assert_between 'source gray-paper background' "$source_gray_background" 0.87 0.91
assert_between 'source bright-paper background' "$source_bright_background" 0.93 0.97
assert_between 'source faint mark' "$source_faint_mark" 0.60 0.72

"$cli" --input "$source_pdf" --output "$output_pdf" \
    --clean-scan standard --grayscale --preserve-metadata none >/dev/null

[[ -s $output_pdf ]]
gs -q -dBATCH -dNOPAUSE -sDEVICE=nullpage -f "$output_pdf"
[[ $(pdfinfo "$output_pdf" | awk -F: \
    '$1 == "Pages" { sub(/^[[:space:]]+/, "", $2); print $2; exit }') -eq 2 ]]
pdfimages -list "$output_pdf" | awk '
    $1 ~ /^[12]$/ && $3 == "image" && $6 == "gray" { pages[$1] = 1 }
    END { exit !(pages[1] && pages[2]) }'
pdftocairo -png -r 100 "$output_pdf" "$test_dir/output-render"
for page in 1 2; do
    [[ $(magick identify -quiet -format '%wx%h' \
        "$test_dir/output-render-$page.png") == 600x800 ]]
done

gray_background=$(region_mean "$test_dir/output-render-1.png" \
    '40x40+20+20')
bright_background=$(region_mean "$test_dir/output-render-2.png" \
    '40x40+20+20')
assert_between 'cleaned gray-paper background' "$gray_background" 0.98 1.00
assert_between 'cleaned bright-paper background' "$bright_background" 0.98 1.00
awk -v gray="$gray_background" -v bright="$bright_background" 'BEGIN {
        difference = gray - bright
        if (difference < 0) difference = -difference
        if (difference > 0.02) {
            printf "cleaned paper tones differ by %.6f\n", difference > "/dev/stderr"
            exit 1
        }
    }'

for page in 1 2; do
    rendered=$test_dir/output-render-$page.png
    dark_ink=$(region_mean "$rendered" '300x30+150+160')
    faint_mark=$(region_mean "$rendered" '400x6+100+498')
    background=$(region_mean "$rendered" '40x40+20+20')
    assert_between "page $page dark ink" "$dark_ink" 0.00 0.12
    assert_between "page $page faint mark" "$faint_mark" 0.25 0.90
    awk -v page="$page" -v background="$background" \
        -v faint_mark="$faint_mark" 'BEGIN {
            if (background - faint_mark < 0.15) {
                printf "page %s: faint mark lacks paper contrast\n", page > "/dev/stderr"
                exit 1
            }
        }'
done

printf '%s\n' 'PDF scan tonal tests passed'
