#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-parallel-test.XXXXXX")

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

PDF_SLIM_TESTING=1
: "$PDF_SLIM_TESTING" # Read by the sourced script.
# shellcheck source=../pdf-slim.sh
# shellcheck disable=SC1091
source "$project_dir/pdf-slim.sh"

mkdir "$test_dir/bin"

cat >"$test_dir/bin/fake-timeout" <<'EOF'
#!/usr/bin/env bash
shift 2
exec "$@"
EOF

cat >"$test_dir/bin/fake-render" <<'EOF'
#!/usr/bin/env bash
set -o errexit
page=''
output=''
while (( $# )); do
    case $1 in
        -f) page=$2; shift 2 ;;
        *) output=$1; shift ;;
    esac
done
while ! mkdir "$PARALLEL_STATE.lock" 2>/dev/null; do sleep 0.01; done
active=$(cat "$PARALLEL_STATE.active")
active=$((active + 1))
printf '%s\n' "$active" >"$PARALLEL_STATE.active"
maximum=$(cat "$PARALLEL_STATE.maximum")
(( active <= maximum )) || printf '%s\n' "$active" >"$PARALLEL_STATE.maximum"
rmdir "$PARALLEL_STATE.lock"
sleep "${PARALLEL_RENDER_DELAY:-0.25}"
printf 'rendered page %s\n' "$page" >"$output.png"
while ! mkdir "$PARALLEL_STATE.lock" 2>/dev/null; do sleep 0.01; done
active=$(cat "$PARALLEL_STATE.active")
printf '%s\n' "$((active - 1))" >"$PARALLEL_STATE.active"
rmdir "$PARALLEL_STATE.lock"
EOF

cat >"$test_dir/bin/fake-clean" <<'EOF'
#!/usr/bin/env bash
set -o errexit
input=''
output=''
while (( $# )); do
    case $1 in
        --input) input=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
page=${output##*/page-}
page=${page%.png}
if [[ ${PARALLEL_FAIL_PAGE:-} == "$page" ]]; then
    printf 'deliberate page failure\n' >&2
    exit 9
fi
cp "$input" "$output"
EOF

cat >"$test_dir/bin/fake-magick" <<'EOF'
#!/usr/bin/env bash
set -o errexit
for arg in "$@"; do
    if [[ $arg == info: ]]; then
        printf '100 100\n'
        exit 0
    fi
done
output=${!#}
printf '%s\n' "$@" >"$PARALLEL_ASSEMBLY_ARGS"
printf 'assembled pdf\n' >"$output"
EOF
chmod +x "$test_dir/bin/"*

reset_state() {
    printf '0\n' >"$test_dir/state.active"
    printf '0\n' >"$test_dir/state.maximum"
    : >"$test_dir/assembly.args"
}

# Prove independently that the controlled renderer records actual overlap.
reset_state
PARALLEL_STATE=$test_dir/state "$test_dir/bin/fake-render" \
    -f 1 source "$test_dir/direct-1" &
first_pid=$!
PARALLEL_STATE=$test_dir/state "$test_dir/bin/fake-render" \
    -f 2 source "$test_dir/direct-2" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
[[ $(cat "$test_dir/state.maximum") -eq 2 ]]

# These globals are consumed by clean_scan_pdf through Bash dynamic scope.
# shellcheck disable=SC2034
inspect_scan_pdf() {
    local page_count=${PARALLEL_PAGE_COUNT:-4}
    local page
    SCAN_PAGE_COUNT=$page_count
    SCAN_PAGE_WIDTH=( '' )
    SCAN_PAGE_HEIGHT=( '' )
    SCAN_X_DPI=( '' )
    SCAN_Y_DPI=( '' )
    for (( page = 1; page <= page_count; page += 1 )); do
        SCAN_PAGE_WIDTH[page]=72
        SCAN_PAGE_HEIGHT[page]=72
        SCAN_X_DPI[page]=100
        SCAN_Y_DPI[page]=100
    done
}

source_pdf=$test_dir/source.pdf
printf 'source\n' >"$source_pdf"
scan_directory=$test_dir/scan
mkdir "$scan_directory"
reset_state
PARALLEL_STATE=$test_dir/state \
PARALLEL_ASSEMBLY_ARGS=$test_dir/assembly.args \
clean_scan_pdf "$source_pdf" "$test_dir/output.pdf" "$scan_directory" \
    standard "$test_dir/bin/fake-timeout" 1m unused-gs \
    "$test_dir/bin/fake-magick" unused-pdfinfo unused-pdfimages \
    unused-pdftotext unused-pdfdetach "$test_dir/bin/fake-render" \
    "$test_dir/bin/fake-clean" 2

[[ $(cat "$test_dir/state.maximum") -eq 2 ]]
[[ -s $test_dir/output.pdf ]]
first=$(grep -n '/cleaned/page-1.png' "$test_dir/assembly.args" | cut -d: -f1)
second=$(grep -n '/cleaned/page-2.png' "$test_dir/assembly.args" | cut -d: -f1)
third=$(grep -n '/cleaned/page-3.png' "$test_dir/assembly.args" | cut -d: -f1)
fourth=$(grep -n '/cleaned/page-4.png' "$test_dir/assembly.args" | cut -d: -f1)
(( first < second && second < third && third < fourth ))

# Automatic selection uses every worker for short PDFs, capped at five.
automatic_directory=$test_dir/automatic-scan
mkdir "$automatic_directory"
reset_state
PARALLEL_STATE=$test_dir/state \
PARALLEL_ASSEMBLY_ARGS=$test_dir/assembly.args PARALLEL_PAGE_COUNT=7 \
clean_scan_pdf "$source_pdf" "$test_dir/automatic.pdf" \
    "$automatic_directory" standard "$test_dir/bin/fake-timeout" 1m \
    unused-gs "$test_dir/bin/fake-magick" unused-pdfinfo \
    unused-pdfimages unused-pdftotext unused-pdfdetach \
    "$test_dir/bin/fake-render" "$test_dir/bin/fake-clean" auto

[[ $(cat "$test_dir/state.maximum") -eq 5 ]]
[[ -s $test_dir/automatic.pdf ]]

short_automatic_directory=$test_dir/short-automatic-scan
mkdir "$short_automatic_directory"
reset_state
PARALLEL_STATE=$test_dir/state \
PARALLEL_ASSEMBLY_ARGS=$test_dir/assembly.args PARALLEL_PAGE_COUNT=3 \
clean_scan_pdf "$source_pdf" "$test_dir/short-automatic.pdf" \
    "$short_automatic_directory" standard "$test_dir/bin/fake-timeout" 1m \
    unused-gs "$test_dir/bin/fake-magick" unused-pdfinfo \
    unused-pdfimages unused-pdftotext unused-pdfdetach \
    "$test_dir/bin/fake-render" "$test_dir/bin/fake-clean" auto

[[ $(cat "$test_dir/state.maximum") -eq 3 ]]
[[ -s $test_dir/short-automatic.pdf ]]

# Prove that the product cleanup helper terminates active page workers rather
# than leaving them writing into a temporary directory after interruption.
interrupt_directory=$test_dir/interrupt-scan
mkdir "$interrupt_directory" "$interrupt_directory/rendered" \
    "$interrupt_directory/cleaned" "$interrupt_directory/workers"
reset_state
PARALLEL_STATE=$test_dir/state PARALLEL_RENDER_DELAY=10 \
clean_scan_page "$source_pdf" "$interrupt_directory" 1 2 standard \
    "$test_dir/bin/fake-timeout" 1m "$test_dir/bin/fake-render" \
    "$test_dir/bin/fake-clean" >/dev/null 2>&1 &
interrupt_first=$!
PARALLEL_STATE=$test_dir/state PARALLEL_RENDER_DELAY=10 \
clean_scan_page "$source_pdf" "$interrupt_directory" 2 2 standard \
    "$test_dir/bin/fake-timeout" 1m "$test_dir/bin/fake-render" \
    "$test_dir/bin/fake-clean" >/dev/null 2>&1 &
interrupt_second=$!
ACTIVE_SCAN_WORKERS=( "$interrupt_first" "$interrupt_second" )
attempt=0
while [[ $(cat "$test_dir/state.maximum") -lt 2 && $attempt -lt 200 ]]; do
    sleep 0.01
    attempt=$((attempt + 1))
done
[[ $(cat "$test_dir/state.maximum") -eq 2 ]]
stop_active_scan_workers
if kill -0 "$interrupt_first" 2>/dev/null || \
    kill -0 "$interrupt_second" 2>/dev/null; then
    printf '%s\n' 'active scan workers survived cleanup' >&2
    exit 1
fi
[[ ${#ACTIVE_SCAN_WORKERS[@]} -eq 0 ]]

failure_directory=$test_dir/failure-scan
mkdir "$failure_directory"
reset_state
if PARALLEL_STATE=$test_dir/state \
    PARALLEL_ASSEMBLY_ARGS=$test_dir/assembly.args PARALLEL_FAIL_PAGE=2 \
    clean_scan_pdf "$source_pdf" "$test_dir/failure.pdf" \
        "$failure_directory" standard "$test_dir/bin/fake-timeout" 1m \
        unused-gs "$test_dir/bin/fake-magick" unused-pdfinfo \
        unused-pdfimages unused-pdftotext unused-pdfdetach \
        "$test_dir/bin/fake-render" "$test_dir/bin/fake-clean" 2 \
        >"$test_dir/failure.out" 2>"$test_dir/failure.err"; then
    printf '%s\n' 'expected one failed page to fail the PDF cleanup' >&2
    exit 1
fi
[[ ! -e $test_dir/failure.pdf ]]
[[ ! -s $test_dir/assembly.args ]]
grep -q 'scan contrast cleanup failed with status 9' \
    "$test_dir/failure.err"

printf '%s\n' 'parallel scan-cleanup tests passed'
