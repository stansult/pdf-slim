#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-cli.XXXXXX")

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/cli" "$test_dir/bin" "$test_dir/input/sub" \
    "$test_dir/other" "$test_dir/empty"
cp "$project_dir/pdf-slim.sh" "$test_dir/cli/pdf-slim.sh"
chmod +x "$test_dir/cli/pdf-slim.sh"
ln -s "$project_dir/tests/fake-gs.sh" "$test_dir/bin/gs"
cli=$test_dir/cli/pdf-slim.sh
test_path=$test_dir/bin:$PATH

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

args_file=$test_dir/gs-args
FAKE_GS_MODE=failure FAKE_GS_ARGS_FILE="$args_file" PATH="$test_path" \
    "$cli" --dry-run --output-dir "$test_dir/dry-output" \
    "$test_dir/input" >"$test_dir/nonrecursive.out" 2>"$test_dir/nonrecursive.err"
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
    "$test_dir/input" >"$test_dir/recursive.out" 2>"$test_dir/recursive.err"
[[ $(grep -c '^would replace if smaller:' "$test_dir/recursive.out") -eq 7 ]]
grep -q 'deep.pdf' "$test_dir/recursive.out"

FAKE_GS_MODE=success PATH="$test_path" "$cli" --quality balanced \
    --output-dir "$test_dir/output" --recursive "$test_dir/input" >/dev/null 2>&1
[[ -s $test_dir/output/one.pdf ]]
[[ -s $test_dir/output/UPPER.PDF ]]
[[ -s "$test_dir/output/name with spaces.pdf" ]]
[[ -s "$test_dir/output/tab	name.pdf" ]]
[[ -s "$test_dir/output/[glob]*.pdf" ]]
[[ -s "$test_dir/output/$newline_name" ]]
[[ -s $test_dir/output/sub/deep.pdf ]]
[[ ! -e $test_dir/output/link.pdf ]]

if PATH="$test_path" "$cli" --output-dir "$test_dir/output" \
    "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected existing output destination to be refused' >&2
    exit 1
fi

if PATH="$test_path" "$cli" --dry-run --output-dir "$test_dir/collision" \
    "$test_dir/input" "$test_dir/other" >/dev/null 2>&1; then
    printf '%s\n' 'expected cross-root destination collision to be refused' >&2
    exit 1
fi

PATH="$test_path" "$cli" --dry-run --replace "$test_dir/empty" \
    >"$test_dir/empty.out" 2>"$test_dir/empty.err"
grep -q 'no PDF files selected for processing' "$test_dir/empty.err"

if PATH="$test_path" "$cli" --replace "$test_dir/missing.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected missing input to fail' >&2
    exit 1
fi
if PATH="$test_path" "$cli" "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected missing output mode to fail' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --replace --output-dir "$test_dir/conflict" \
    "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected mutually exclusive output modes to fail' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --quality unknown --replace \
    "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected unknown quality to fail' >&2
    exit 1
fi
if PATH="$test_path" "$cli" --preserve-metadata unknown --replace \
    "$test_dir/input/one.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected unknown metadata mode to fail' >&2
    exit 1
fi

leading_dir=$test_dir/leading
mkdir "$leading_dir"
printf '%100s\n' '%PDF-1.7 leading' >"$leading_dir/-leading.pdf"
(
    cd "$leading_dir"
    PATH="$test_path" "$cli" --dry-run --replace -- -leading.pdf >/dev/null
)

PATH="$test_path" "$cli" --dry-run --replace "$test_dir/input/link.pdf" \
    >"$test_dir/symlink.out" 2>"$test_dir/symlink.err"
grep -q 'skipping symlink:' "$test_dir/symlink.err"
[[ ! -s $test_dir/symlink.out ]]

printf '%s\n' 'CLI integration tests passed'
