#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-real-gs.XXXXXX")

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

command -v gs >/dev/null 2>&1 || {
    printf '%s\n' 'Ghostscript is required for the real conversion test' >&2
    exit 1
}
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || {
    printf '%s\n' 'GNU timeout is required for the real conversion test' >&2
    exit 1
}

mkdir "$test_dir/cli"
cp "$project_dir/pdf-slim.sh" "$test_dir/cli/pdf-slim.sh"
chmod +x "$test_dir/cli/pdf-slim.sh"
cli=$test_dir/cli/pdf-slim.sh

source_ps=$test_dir/source.ps
source_pdf=$test_dir/source.pdf
printf '%s\n' \
    '%!PS' \
    '/Helvetica findfont 18 scalefont setfont' \
    '0.1 0.3 0.8 setrgbcolor' \
    '72 720 moveto (pdf-slim real Ghostscript test) show' \
    'showpage' >"$source_ps"
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite "-sOutputFile=$source_pdf" \
    -f "$source_ps"

for quality in preserve balanced small; do
    for color_mode in color grayscale; do
        output_dir=$test_dir/$quality-$color_mode
        if [[ $color_mode == grayscale ]]; then
            "$cli" --quality "$quality" --grayscale --output-dir "$output_dir" \
                "$source_pdf" >/dev/null
        else
            "$cli" --quality "$quality" --output-dir "$output_dir" \
                "$source_pdf" >/dev/null
        fi
        output_pdf=$output_dir/source.pdf
        [[ -s $output_pdf ]]
        gs -q -dBATCH -dNOPAUSE -sDEVICE=nullpage -f "$output_pdf"
    done
done

replace_pdf=$test_dir/replace.pdf
cp "$source_pdf" "$replace_pdf"
dd if=/dev/zero bs=1024 count=100 >>"$replace_pdf" 2>/dev/null
original_size=$(stat -f '%z' "$replace_pdf")
"$cli" --quality balanced --replace "$replace_pdf" >/dev/null
[[ $(stat -f '%z' "$replace_pdf") -lt $original_size ]]
gs -q -dBATCH -dNOPAUSE -sDEVICE=nullpage -f "$replace_pdf"

printf '%s\n' 'real Ghostscript tests passed'
