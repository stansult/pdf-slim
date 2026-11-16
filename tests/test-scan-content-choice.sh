#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-content-choice.XXXXXX")

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

export PDF_SLIM_STATE_DIR=$test_dir/state

command -v expect >/dev/null
command -v gs >/dev/null
command -v pdftotext >/dev/null

make_image_page_ps() {
    local output=$1
    local overlay_text=${2:-}

    {
        printf '%s\n' \
            '%!PS' \
            '<< /PageSize [612 792] >> setpagedevice' \
            '/row 300 string def' \
            '0 1 299 { row exch 245 put } for' \
            'gsave' \
            '72 432 translate' \
            '144 144 scale' \
            '300 300 8 [300 0 0 -300 0 300] { row } image' \
            'grestore'
        if [[ -n $overlay_text ]]; then
            printf '%s\n' \
                '/Helvetica findfont 18 scalefont setfont' \
                "72 720 moveto ($overlay_text) show"
        fi
        printf '%s\n' 'showpage'
    } >"$output"
}

run_choice() {
    local choice=$1
    local input=$2
    local output=$3
    local log=$4

    # Tcl expands the environment references inside this single-quoted script.
    # shellcheck disable=SC2016
    CHOICE=$choice INPUT=$input OUTPUT=$output LOG_FILE=$log \
        PROJECT_DIR=$project_dir expect -c '
            log_user 0
            log_file -noappend -a $env(LOG_FILE)
            set timeout 120
            spawn -noecho $env(PROJECT_DIR)/pdf-slim.sh \
                --input $env(INPUT) --output $env(OUTPUT) \
                --clean-scan standard --quality balanced \
                --grayscale --preserve-metadata none
            expect {
                -exact {Choice [q]:} { send "$env(CHOICE)\r"; exp_continue }
                timeout { exit 124 }
                eof
            }
            set result [wait]
            exit [lindex $result 3]
        '
}

image_ps=$test_dir/image.ps
image_pdf=$test_dir/image.pdf
overlay_ps=$test_dir/overlay.ps
overlay_pdf=$test_dir/overlay.pdf
make_image_page_ps "$image_ps"
make_image_page_ps "$overlay_ps" 'searchable overlay text'
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite \
    "-sOutputFile=$image_pdf" -f "$image_ps"
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite \
    "-sOutputFile=$overlay_pdf" -f "$overlay_ps"
pdfimages -list "$overlay_pdf" | awk \
    '$3 == "image" { images += 1 } END { exit !(images == 1) }'
pdftotext "$overlay_pdf" - | grep -q 'searchable overlay text'

noninteractive_output=$test_dir/noninteractive.pdf
if "$project_dir/pdf-slim.sh" --input "$overlay_pdf" \
    --output "$noninteractive_output" --clean-scan standard \
    --preserve-metadata none </dev/null \
    >"$test_dir/noninteractive.out" 2>"$test_dir/noninteractive.err"; then
    printf '%s\n' 'expected non-interactive searchable-text cleanup to fail' >&2
    exit 1
fi
[[ ! -e $noninteractive_output ]]
grep -q 'cannot ask for a choice in a non-interactive session' \
    "$test_dir/noninteractive.err"
[[ $(($(wc -l <"$PDF_SLIM_STATE_DIR/performance.tsv") - 1)) -eq 1 ]]

preserved_output=$test_dir/preserved.pdf
run_choice p "$overlay_pdf" "$preserved_output" "$test_dir/preserve.log"
[[ -s $preserved_output ]]
pdftotext "$preserved_output" - | grep -q 'searchable overlay text'
pdfimages -list "$preserved_output" | awk \
    '$3 == "image" { images += 1; gray = ($6 == "gray") }
    END { exit !(images == 1 && gray) }'
grep -Fq '[p] Preserve text — continue without scan cleanup; apply all other options' \
    "$test_dir/preserve.log"
[[ $(($(wc -l <"$PDF_SLIM_STATE_DIR/performance.tsv") - 1)) -eq 1 ]]

cleaned_output=$test_dir/cleaned.pdf
run_choice c "$overlay_pdf" "$cleaned_output" "$test_dir/clean.log"
[[ -s $cleaned_output ]]
if pdftotext "$cleaned_output" - | LC_ALL=C tr -d '[:space:]' | grep -q .; then
    printf '%s\n' 'clean choice unexpectedly retained searchable text' >&2
    exit 1
fi
grep -Fq '[c] Clean scan — rasterize pages (searchable text will be removed!)' \
    "$test_dir/clean.log"
[[ $(($(wc -l <"$PDF_SLIM_STATE_DIR/performance.tsv") - 1)) -eq 2 ]]

quit_output=$test_dir/quit.pdf
if run_choice '' "$overlay_pdf" "$quit_output" "$test_dir/quit.log"; then
    printf '%s\n' 'expected quit choice to stop with status 2' >&2
    exit 1
else
    status=$?
fi
[[ $status -eq 2 ]]
[[ ! -e $quit_output ]]
grep -Fq '[q] Quit — stop processing' "$test_dir/quit.log"
if grep -q 'previously processed files remain saved' "$test_dir/quit.log"; then
    printf '%s\n' 'first-file quit unexpectedly claimed prior saved files' >&2
    exit 1
fi
[[ $(($(wc -l <"$PDF_SLIM_STATE_DIR/performance.tsv") - 1)) -eq 2 ]]

batch_output=$test_dir/batch-output
# Tcl expands the environment references inside this single-quoted script.
# shellcheck disable=SC2016
CHOICE=q FIRST_INPUT=$image_pdf SECOND_INPUT=$overlay_pdf \
    OUTPUT_DIR=$batch_output LOG_FILE=$test_dir/batch.log \
    PROJECT_DIR=$project_dir expect -c '
        log_user 0
        log_file -noappend -a $env(LOG_FILE)
        set timeout 120
        spawn -noecho $env(PROJECT_DIR)/pdf-slim.sh \
            --input $env(FIRST_INPUT) --input $env(SECOND_INPUT) \
            --output-dir $env(OUTPUT_DIR) --clean-scan standard \
            --quality balanced --preserve-metadata none
        expect {
            -exact {Choice [q]:} { send "$env(CHOICE)\r"; exp_continue }
            timeout { exit 124 }
            eof
        }
        set result [wait]
        exit [lindex $result 3]
    ' && {
        printf '%s\n' 'expected batch quit choice to stop with status 2' >&2
        exit 1
    }
[[ -s $batch_output/image.pdf ]]
[[ ! -e $batch_output/overlay.pdf ]]
grep -Fq '[q] Quit — stop processing (previously processed files remain saved)' \
    "$test_dir/batch.log"
[[ $(($(wc -l <"$PDF_SLIM_STATE_DIR/performance.tsv") - 1)) -eq 3 ]]

printf '%s\n' 'scan content choice tests passed'
