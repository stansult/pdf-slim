#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-cli.XXXXXX")
export PDF_SLIM_STATE_DIR=$test_dir/state

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/cli" "$test_dir/bin" "$test_dir/input/sub" \
    "$test_dir/other" "$test_dir/empty" "$test_dir/glob-input"
cp "$project_dir/pdf-slim.sh" "$test_dir/cli/pdf-slim.sh"
chmod +x "$test_dir/cli/pdf-slim.sh"
ln -s "$project_dir/tests/fake-gs.sh" "$test_dir/bin/gs"
cli=$test_dir/cli/pdf-slim.sh
test_path=$test_dir/bin:$PATH

PATH="$test_path" "$cli" --help >"$test_dir/help-long.out"
PATH="$test_path" "$cli" -h >"$test_dir/help-short.out"
cmp "$test_dir/help-long.out" "$test_dir/help-short.out"
grep -q -- '-h, --help' "$test_dir/help-long.out"
grep -q -- 'Quality -- choose one approach:' "$test_dir/help-long.out"
grep -q -- '--max-dpi DPI' "$test_dir/help-long.out"
grep -q -- '--jpeg-recompress Q' "$test_dir/help-long.out"
grep -q -- 'Do not combine --quality' "$test_dir/help-long.out"
grep -q -- '--clean-scan MODE' "$test_dir/help-long.out"
grep -q -- 'gentle, standard, or' "$test_dir/help-long.out"
grep -q -- 'safely reduces PDF file sizes' "$test_dir/help-long.out"
grep -q -- 'For image output, use scan-clean.sh.' "$test_dir/help-long.out"
grep -q -- '-i scan.jpg -o scan-cleaned.pdf --clean-scan standard' \
    "$test_dir/help-long.out"
grep -q -- 'https://github.com/stansult/pdf-slim' "$test_dir/help-long.out"
[[ $(PATH="$test_path" "$cli" --version) == 'pdf-slim.sh 1.2.0' ]]

if PATH="$test_path" "$cli" >"$test_dir/no-args.out" 2>"$test_dir/no-args.err"; then
    printf '%s\n' 'expected an invocation without arguments to fail' >&2
    exit 1
fi
[[ ! -s $test_dir/no-args.out ]]
grep -q -- '--input \. --output-dir slimmed' "$test_dir/no-args.err"
grep -q -- '--input \. --replace' "$test_dir/no-args.err"
grep -q -- '--help' "$test_dir/no-args.err"
awk 'NR == 1 { next } NR == 2 { exit !($0 == "") }' \
    "$test_dir/no-args.err"
awk '/For a scanned image:/ { seen = 1; next }
    seen && /^Run .*--help/ { exit !previous_blank }
    { previous_blank = ($0 == "") }
    END { if (!seen) exit 1 }' "$test_dir/no-args.err"

printf '%100s\n' '%PDF-1.7 one' >"$test_dir/input/one.pdf"
printf '%100s\n' '%PDF-1.7 uppercase' >"$test_dir/input/UPPER.PDF"
printf '%100s\n' '%PDF-1.7 spaces' >"$test_dir/input/name with spaces.pdf"
printf '%100s\n' '%PDF-1.7 tab' >"$test_dir/input/tab	name.pdf"
printf '%100s\n' '%PDF-1.7 glob' >"$test_dir/input/[glob]*.pdf"
newline_name=$'line\nbreak.pdf'
printf '%100s\n' '%PDF-1.7 newline' >"$test_dir/input/$newline_name"
printf '%100s\n' '%PDF-1.7 deep' >"$test_dir/input/sub/deep.pdf"
printf '%s\n' 'not a PDF' >"$test_dir/input/not.txt"
ln -s "$test_dir/input/one.pdf" "$test_dir/input/link.pdf"
printf '%100s\n' '%PDF-1.7 collision' >"$test_dir/other/one.pdf"
printf '%100s\n' '%PDF-1.7 glob one' >"$test_dir/glob-input/doc-one.pdf"
printf '%100s\n' '%PDF-1.7 glob two' >"$test_dir/glob-input/doc two.pdf"
printf '%100s\n' '%PDF-1.7 glob other' >"$test_dir/glob-input/other.pdf"

PATH="$test_path" "$cli" --dry-run \
    -i "$test_dir/glob-input/doc*.pdf" \
    --output-dir "$test_dir/glob-output" >"$test_dir/glob.out"
[[ $(grep -c '^would convert:' "$test_dir/glob.out") -eq 2 ]]
grep -q 'doc-one.pdf' "$test_dir/glob.out"
grep -q 'doc two.pdf' "$test_dir/glob.out"
[[ ! -e $test_dir/glob-output ]]

if PATH="$test_path" "$cli" --dry-run \
    -i "$test_dir/glob-input/missing*.pdf" \
    --output-dir "$test_dir/missing-glob-output" \
    >"$test_dir/missing-glob.out" 2>"$test_dir/missing-glob.err"; then
    printf '%s\n' 'expected a no-match input pattern to fail' >&2
    exit 1
fi
grep -q 'input pattern matched no paths' "$test_dir/missing-glob.err"
[[ ! -e $test_dir/missing-glob-output ]]

literal_glob_output=$test_dir/literal-glob-output.pdf
PATH="$test_path" "$cli" --dry-run \
    -i "$test_dir/input/[glob]*.pdf" -o "$literal_glob_output" \
    >"$test_dir/literal-glob.out"
[[ $(grep -c '^would convert:' "$test_dir/literal-glob.out") -eq 1 ]]
grep -Fq "$test_dir/input/[glob]*.pdf" "$test_dir/literal-glob.out"
[[ ! -e $literal_glob_output ]]

if PATH="$test_path" "$cli" -i "$test_dir/glob-input"/doc*.pdf \
    --output-dir "$test_dir/unquoted-glob-output" \
    >"$test_dir/unquoted-glob.out" 2>"$test_dir/unquoted-glob.err"; then
    printf '%s\n' 'expected an unquoted multi-match pattern to fail' >&2
    exit 1
fi
grep -q 'shell may have expanded an unquoted input pattern' \
    "$test_dir/unquoted-glob.err"
grep -q "quote patterns passed to --input" "$test_dir/unquoted-glob.err"
[[ ! -e $test_dir/unquoted-glob-output ]]

exact_output=$test_dir/exact-output.pdf
FAKE_GS_MODE=success PATH="$test_path" \
    "$cli" -i "$test_dir/input/one.pdf" -o "$exact_output" >/dev/null
[[ -s $exact_output ]]
[[ ! -e $test_dir/cli/processed_pdfs.log ]]

exact_dry_output=$test_dir/exact-dry-output.pdf
exact_dry_args=$test_dir/exact-dry-args
FAKE_GS_MODE=failure FAKE_GS_ARGS_FILE="$exact_dry_args" PATH="$test_path" \
    "$cli" --dry-run --input "$test_dir/input/one.pdf" \
    --output "$exact_dry_output" >"$test_dir/exact-dry.out"
[[ ! -e $exact_dry_output ]]
[[ ! -e $exact_dry_args ]]
grep -q "would convert: .* -> $exact_dry_output" "$test_dir/exact-dry.out"

custom_output=$test_dir/custom-output.pdf
custom_args=$test_dir/custom-args
FAKE_GS_MODE=success FAKE_GS_ARGS_FILE="$custom_args" PATH="$test_path" \
    "$cli" -i "$test_dir/input/one.pdf" -o "$custom_output" \
    --max-dpi 275 --jpeg-recompress 0.20 >/dev/null
[[ -s $custom_output ]]
grep -Fx -- '-dColorImageResolution=275' "$custom_args" >/dev/null
grep -Fx -- '-dPassThroughJPEGImages=false' "$custom_args" >/dev/null
grep -F -- '/QFactor 0.20' "$custom_args" >/dev/null

exact_failure_output=$test_dir/exact-failure-output.pdf
exact_source_hash=$(shasum -a 256 "$test_dir/input/one.pdf")
if FAKE_GS_MODE=partial-failure PATH="$test_path" \
    "$cli" -i "$test_dir/input/one.pdf" -o "$exact_failure_output" \
    >/dev/null 2>&1; then
    printf '%s\n' 'expected an exact-output conversion failure' >&2
    exit 1
fi
[[ ! -e $exact_failure_output ]]
[[ $(shasum -a 256 "$test_dir/input/one.pdf") == "$exact_source_hash" ]]

if PATH="$test_path" "$cli" -i "$test_dir/input/one.pdf" \
    -o "$exact_output" >/dev/null 2>&1; then
    printf '%s\n' 'expected an existing exact output to be refused' >&2
    exit 1
fi
if PATH="$test_path" "$cli" -o "$test_dir/multiple.pdf" \
    -i "$test_dir/input/one.pdf" -i "$test_dir/input/UPPER.PDF" \
    >/dev/null 2>&1; then
    printf '%s\n' 'expected exact output with multiple inputs to be refused' >&2
    exit 1
fi
if PATH="$test_path" "$cli" -o "$test_dir/directory.pdf" \
    -i "$test_dir/input" >/dev/null 2>&1; then
    printf '%s\n' 'expected exact output with a directory input to be refused' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --recursive -o "$test_dir/recursive.pdf" \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected recursive exact output to be refused' >&2
    exit 1
fi
if PATH="$test_path" "$cli" -o "$test_dir/missing/output.pdf" \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected a missing exact-output parent to be refused' >&2
    exit 1
fi
ln -s "$test_dir/symlink-target.pdf" "$test_dir/symlink-output.pdf"
if PATH="$test_path" "$cli" -o "$test_dir/symlink-output.pdf" \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected a symlink exact output to be refused' >&2
    exit 1
fi
[[ ! -e $test_dir/symlink-target.pdf ]]
if PATH="$test_path" "$cli" -o "$test_dir/conflict-file.pdf" --replace \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected exact output and replacement to conflict' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --output-dir "$test_dir/conflict-dir" \
    -o "$test_dir/conflict-file.pdf" -i "$test_dir/input/one.pdf" \
    >/dev/null 2>&1; then
    printf '%s\n' 'expected exact and directory output modes to conflict' >&2
    exit 1
fi

args_file=$test_dir/gs-args
FAKE_GS_MODE=failure FAKE_GS_ARGS_FILE="$args_file" PATH="$test_path" \
    "$cli" --dry-run --output-dir "$test_dir/dry-output" \
    -i "$test_dir/input" >"$test_dir/nonrecursive.out" 2>"$test_dir/nonrecursive.err"
[[ ! -e $test_dir/dry-output ]]
[[ ! -e $args_file ]]
[[ $(grep -c '^would convert:' "$test_dir/nonrecursive.out") -eq 6 ]]
if grep -q 'deep.pdf' "$test_dir/nonrecursive.out"; then
    printf '%s\n' 'non-recursive traversal unexpectedly selected a nested PDF' >&2
    exit 1
fi
grep -q 'skipping symlink:' "$test_dir/nonrecursive.err"
grep -q 'skipping non-PDF file:' "$test_dir/nonrecursive.err"

PATH="$test_path" "$cli" --dry-run --replace --recursive \
    -i "$test_dir/input" >"$test_dir/recursive.out" 2>"$test_dir/recursive.err"
[[ $(grep -c '^would replace if smaller:' "$test_dir/recursive.out") -eq 7 ]]
grep -q 'deep.pdf' "$test_dir/recursive.out"

FAKE_GS_MODE=success PATH="$test_path" "$cli" --quality balanced \
    --output-dir "$test_dir/output" --recursive \
    -i "$test_dir/input" >/dev/null 2>&1
[[ -s $test_dir/output/one.pdf ]]
[[ -s $test_dir/output/UPPER.PDF ]]
[[ -s "$test_dir/output/name with spaces.pdf" ]]
[[ -s "$test_dir/output/tab	name.pdf" ]]
[[ -s "$test_dir/output/[glob]*.pdf" ]]
[[ -s "$test_dir/output/$newline_name" ]]
[[ -s $test_dir/output/sub/deep.pdf ]]
[[ ! -e $test_dir/output/link.pdf ]]

if PATH="$test_path" "$cli" --output-dir "$test_dir/output" \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected existing output destination to be refused' >&2
    exit 1
fi

if PATH="$test_path" "$cli" --dry-run --output-dir "$test_dir/collision" \
    -i "$test_dir/input" -i "$test_dir/other" >/dev/null 2>&1; then
    printf '%s\n' 'expected cross-root destination collision to be refused' >&2
    exit 1
fi

PATH="$test_path" "$cli" --dry-run --replace -i "$test_dir/empty" \
    >"$test_dir/empty.out" 2>"$test_dir/empty.err"
grep -q 'no PDF files selected for processing' "$test_dir/empty.err"

if PATH="$test_path" "$cli" --replace -i "$test_dir/missing.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected missing input to fail' >&2
    exit 1
fi
if PATH="$test_path" "$cli" -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected missing output mode to fail' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --replace --output-dir "$test_dir/conflict" \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected mutually exclusive output modes to fail' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --quality unknown --replace \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected unknown quality to fail' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --quality balanced --max-dpi 275 --replace \
    -i "$test_dir/input/one.pdf" \
    >"$test_dir/quality-conflict.out" 2>"$test_dir/quality-conflict.err"; then
    printf '%s\n' 'expected preset and detailed quality options to conflict' >&2
    exit 1
fi
grep -q 'choose one quality approach' "$test_dir/quality-conflict.err"
if PATH="$test_path" "$cli" --clean-scan extreme --replace \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected unknown scan cleanup mode to fail' >&2
    exit 1
fi
PATH="$test_path" "$cli" --dry-run --clean-scan standard --replace \
    -i "$test_dir/input/one.pdf" >"$test_dir/clean-dry.out"
grep -q 'would clean scan (standard):' "$test_dir/clean-dry.out"
if PATH="$test_path" "$cli" --max-dpi 0 --replace \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected zero maximum DPI to be refused' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --max-dpi 275.5 --replace \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected a non-integer maximum DPI to be refused' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --jpeg-recompress 1.1 --replace \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected an out-of-range QFactor to be refused' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --jpeg-recompress -0.1 --replace \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected a negative QFactor to be refused' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --preserve-metadata unknown --replace \
    -i "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected unknown metadata mode to fail' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --replace "$test_dir/input/one.pdf" \
    >"$test_dir/positional.out" 2>"$test_dir/positional.err"; then
    printf '%s\n' 'expected a positional input to be refused' >&2
    exit 1
fi
grep -q 'use --input PATH' "$test_dir/positional.err"
if PATH="$test_path" "$cli" --replace -- \
    >"$test_dir/double-dash.out" 2>"$test_dir/double-dash.err"; then
    printf '%s\n' "expected '--' to be refused" >&2
    exit 1
fi
grep -q "'--' is not supported; use --input PATH" "$test_dir/double-dash.err"

leading_dir=$test_dir/leading
mkdir "$leading_dir"
printf '%100s\n' '%PDF-1.7 leading' >"$leading_dir/-leading.pdf"
(
    cd "$leading_dir"
    PATH="$test_path" "$cli" --dry-run --replace -i -leading.pdf >/dev/null
    FAKE_GS_MODE=success PATH="$test_path" \
        "$cli" -o -output.pdf -i -leading.pdf >/dev/null
    [[ -s ./-output.pdf ]]
)

PATH="$test_path" "$cli" --dry-run --replace -i "$test_dir/input/link.pdf" \
    >"$test_dir/symlink.out" 2>"$test_dir/symlink.err"
grep -q 'skipping symlink:' "$test_dir/symlink.err"
[[ ! -s $test_dir/symlink.out ]]

printf '%s\n' 'CLI integration tests passed'
