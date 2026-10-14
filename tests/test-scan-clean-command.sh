#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "$project_dir/.scan-clean-tests.XXXXXX")
cli=$project_dir/scan-clean.sh
real_magick=$(command -v magick)

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/input/sub"

"$cli" --help >"$test_dir/help-long.out"
"$cli" -h >"$test_dir/help-short.out"
cmp "$test_dir/help-long.out" "$test_dir/help-short.out"
grep -q -- '-i, --input PATH' "$test_dir/help-long.out"
grep -q -- '-O, --overwrite' "$test_dir/help-long.out"
grep -q -- '--all-modes' "$test_dir/help-long.out"
grep -q -- '-v, --verbose' "$test_dir/help-long.out"
grep -q -- 'standard (default)' "$test_dir/help-long.out"
grep -q -- 'improves photographed and scanned document images' \
    "$test_dir/help-long.out"
grep -q -- 'For PDF output, use pdf-slim.sh.' "$test_dir/help-long.out"
grep -q -- '-i scan.png -o scan-cleaned.jpg' "$test_dir/help-long.out"
grep -q -- 'https://github.com/stansult/pdf-slim' "$test_dir/help-long.out"
if grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}\]$|^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' \
    "$test_dir/help-long.out"; then
    printf '%s\n' 'help output must not be timestamped' >&2
    exit 1
fi
[[ $("$cli" --version) == 'scan-clean.sh 1.0.1' ]]

if "$cli" >"$test_dir/no-input.out" 2>"$test_dir/no-input.err"; then
    printf '%s\n' 'expected missing input to fail' >&2
    exit 1
fi
grep -q -- '--input is required' "$test_dir/no-input.err"
grep -q -- '--input scan.png -o scan-cleaned.jpg' "$test_dir/no-input.err"
grep -q -- '--input scan.jpg --all-modes' "$test_dir/no-input.err"
grep -q -- '--input \. --output-dir cleaned' "$test_dir/no-input.err"
grep -q -- '--help' "$test_dir/no-input.err"
sed -n '1p' "$test_dir/no-input.err" | \
    grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}\]$'
sed -n '2p' "$test_dir/no-input.err" | \
    grep -Eq '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] scan-clean[.]sh: error:'
awk 'NR == 3 { exit !($0 == "") }' "$test_dir/no-input.err"
[[ $(sed -n '4p' "$test_dir/no-input.err") == \
    'Choose how to write cleaned images:' ]]
awk '/For the current directory:/ { seen = 1; next }
    seen && /Run .*--help/ { exit !previous_blank }
    { previous_blank = ($0 == "") }
    END { if (!seen) exit 1 }' "$test_dir/no-input.err"

"$real_magick" -size 80x60 -units PixelsPerInch -density 300 xc:'#e4d4bd' \
    -fill '#352b28' -draw 'rectangle 15,15 65,45' \
    -set comment 'scan-clean metadata' -quality 88 "$test_dir/input/scan.jpg"
"$real_magick" -size 40x30 xc:none -fill black \
    -draw 'rectangle 10,8 30,22' "$test_dir/input/alpha.png"
"$real_magick" -size 20x10 xc:white "$test_dir/input/sub/nested.png"
printf '%s\n' 'not an image' >"$test_dir/input/note.txt"
ln -s "$test_dir/input/scan.jpg" "$test_dir/input/link.jpg"

"$cli" -i "$test_dir/input/scan.jpg" >"$test_dir/default.out"
default_output=$test_dir/input/scan-standard.jpg
[[ -s $default_output ]]
grep -q "created: $default_output" "$test_dir/default.out"
[[ $("$real_magick" identify -quiet -format '%wx%h' "$default_output") == 80x60 ]]
[[ $("$real_magick" identify -quiet -format '%x' "$default_output") == 300 ]]
[[ $("$real_magick" identify -quiet -format '%[comment]' "$default_output") == \
    'scan-clean metadata' ]]

"$cli" -i "$test_dir/input/scan.jpg" --strip-metadata \
    -o "$test_dir/stripped.jpg" >/dev/null
[[ -z $("$real_magick" identify -quiet -format '%[comment]' \
    "$test_dir/stripped.jpg") ]]

"$cli" -v -i "$test_dir/input/scan.jpg" \
    -o "$test_dir/verbose-stage.jpg" \
    >"$test_dir/verbose-stage.out" 2>"$test_dir/verbose-stage.err"
grep -q 'verbose: inspecting document background:' \
    "$test_dir/verbose-stage.err"
grep -q 'verbose: applying standard cleanup:' "$test_dir/verbose-stage.err"
grep -q 'verbose: validating cleaned image:' "$test_dir/verbose-stage.err"
grep -q 'verbose: publishing output atomically:' \
    "$test_dir/verbose-stage.err"
grep -q 'created:' "$test_dir/verbose-stage.out"

"$cli" -i "$test_dir/input/scan.jpg" >/dev/null
[[ -s $test_dir/input/scan-2-standard.jpg ]]

mkdir "$test_dir/all"
cp "$test_dir/input/scan.jpg" "$test_dir/all/document.jpg"
touch "$test_dir/all/document-standard.jpg"
"$cli" -i "$test_dir/all/document.jpg" --all-modes >/dev/null
[[ -s $test_dir/all/document-2-gentle.jpg ]]
[[ -s $test_dir/all/document-2-standard.jpg ]]
[[ -s $test_dir/all/document-2-strong.jpg ]]
[[ $(shasum -a 256 "$test_dir/all/document-2-gentle.jpg") != \
    $(shasum -a 256 "$test_dir/all/document-2-strong.jpg") ]]

original_hash=$(shasum -a 256 "$default_output")
"$cli" -i "$test_dir/input/scan.jpg" -O >/dev/null
[[ -s $default_output ]]
[[ $(shasum -a 256 "$default_output") != "$original_hash" || \
    $("$real_magick" identify -quiet -format '%m' "$default_output") == JPEG ]]

"$cli" -i "$test_dir/input/alpha.png" -o "$test_dir/alpha-clean.png" >/dev/null
[[ $("$real_magick" identify -quiet -format '%[opaque]' \
    "$test_dir/alpha-clean.png") == False ]]
"$cli" -i "$test_dir/input/alpha.png" -o "$test_dir/alpha-clean.jpg" \
    --background white --jpeg-quality 91 >/dev/null
[[ $("$real_magick" identify -quiet -format '%[opaque]' \
    "$test_dir/alpha-clean.jpg") == True ]]
[[ $("$real_magick" identify -quiet -format '%Q' \
    "$test_dir/alpha-clean.jpg") == 91 ]]

"$cli" -i "$test_dir/input" --output-dir "$test_dir/new/cleaned" \
    >"$test_dir/batch.out" 2>"$test_dir/batch.err"
[[ -s $test_dir/new/cleaned/scan-standard.jpg ]]
[[ -s $test_dir/new/cleaned/alpha-standard.png ]]
[[ ! -e $test_dir/new/cleaned/nested-standard.png ]]
grep -q 'skipping symlink:' "$test_dir/batch.err"
grep -q 'skipping unsupported, multi-frame, or unreadable image:' \
    "$test_dir/batch.err"

mkdir "$test_dir/glob-output"
"$cli" -i "$test_dir/input/*.*" --output-dir "$test_dir/glob-output" \
    --dry-run >"$test_dir/glob.out" 2>"$test_dir/glob.err"
grep -q 'would create:' "$test_dir/glob.out"
[[ ! -e $test_dir/glob-output/scan-standard.jpg ]]

verbose_output=$test_dir/verbose.jpg
"$cli" -v -i "$test_dir/input/scan.jpg" -o "$verbose_output" --dry-run \
    >"$test_dir/verbose.out" 2>"$test_dir/verbose.err"
grep -q 'verbose: selected 1 image(s)' "$test_dir/verbose.err"
grep -q 'verbose: cleanup mode: standard (default)' "$test_dir/verbose.err"
grep -q 'verbose: JPEG quality: 95' "$test_dir/verbose.err"
grep -q 'verbose: metadata: preserve supported metadata' \
    "$test_dir/verbose.err"
grep -q 'would create:' "$test_dir/verbose.out"
[[ ! -e $verbose_output ]]

mkdir "$test_dir/symlink-target"
ln -s "$test_dir/symlink-target" "$test_dir/symlink-component"
if "$cli" -i "$test_dir/input/scan.jpg" \
    --output-dir "$test_dir/symlink-component/cleaned" >/dev/null 2>&1; then
    printf '%s\n' 'expected a symlink output-directory component to fail' >&2
    exit 1
fi
[[ ! -e $test_dir/symlink-target/cleaned ]]

if "$cli" -i "$test_dir/input/scan.jpg" \
    -o "$test_dir/not-an-image.pdf" >/dev/null 2>&1; then
    printf '%s\n' 'expected a document output extension to fail' >&2
    exit 1
fi
if "$cli" -i "$test_dir/input/scan.jpg" --background not-a-real-color \
    --output-dir "$test_dir/invalid-background" >/dev/null 2>&1; then
    printf '%s\n' 'expected an invalid background color to fail' >&2
    exit 1
fi
[[ ! -e $test_dir/invalid-background ]]
if "$cli" -i "$test_dir/input/scan.jpg" --timeout nonsense \
    --output-dir "$test_dir/invalid-timeout" >/dev/null 2>&1; then
    printf '%s\n' 'expected an invalid timeout to fail' >&2
    exit 1
fi
[[ ! -e $test_dir/invalid-timeout ]]
touch "$test_dir/existing.jpg"
if "$cli" -i "$test_dir/input/scan.jpg" \
    -o "$test_dir/existing.jpg" >/dev/null 2>&1; then
    printf '%s\n' 'expected an existing exact output to fail without overwrite' >&2
    exit 1
fi
if "$cli" -i "$test_dir/input/scan.jpg" \
    -o "$test_dir/missing/output.jpg" >/dev/null 2>&1; then
    printf '%s\n' 'expected a missing exact-output parent to fail' >&2
    exit 1
fi
[[ ! -e $test_dir/missing ]]
if "$cli" -i "$test_dir/input/scan.jpg" --all-modes \
    -o "$test_dir/conflict.jpg" >/dev/null 2>&1; then
    printf '%s\n' 'expected --all-modes and --output to conflict' >&2
    exit 1
fi
if "$cli" -i "$test_dir/input/scan.jpg" \
    -i "$test_dir/input/alpha.png" --output-dir "$test_dir/repeated" \
    >/dev/null 2>&1; then
    printf '%s\n' 'expected repeated --input to fail' >&2
    exit 1
fi
[[ ! -e $test_dir/repeated ]]
if "$cli" -i "$test_dir/input/scan.jpg" --all-modes \
    --mode gentle >/dev/null 2>&1; then
    printf '%s\n' 'expected --all-modes and --mode to conflict' >&2
    exit 1
fi

"$real_magick" -size 10x10 xc:white -size 10x10 xc:black \
    "$test_dir/animated.gif"
if "$cli" -i "$test_dir/animated.gif" >/dev/null 2>&1; then
    printf '%s\n' 'expected a multi-frame image to fail' >&2
    exit 1
fi

mkdir "$test_dir/bin"
ln -s "$project_dir/tests/fake-magick.sh" "$test_dir/bin/magick"

wait_for_file() {
    local file=$1
    local attempt=0

    while [[ ! -e $file && $attempt -lt 100 ]]; do
        sleep 0.05
        ((attempt += 1))
    done
    [[ -e $file ]]
}

# Validate the fake ImageMagick barrier independently of the product command.
fixture_ready=$test_dir/fixture.ready
fixture_release=$test_dir/fixture.release
fixture_output=$test_dir/fixture-output.jpg
REAL_MAGICK="$real_magick" FAKE_MAGICK_READY_FILE="$fixture_ready" \
    FAKE_MAGICK_RELEASE_FILE="$fixture_release" \
    "$project_dir/tests/fake-magick.sh" "$test_dir/input/scan.jpg" \
    "$fixture_output" &
fixture_pid=$!
wait_for_file "$fixture_ready"
kill -0 "$fixture_pid"
[[ ! -e $fixture_output ]]
: >"$fixture_release"
wait "$fixture_pid"
[[ -s $fixture_output ]]

failure_output=$test_dir/failure.jpg
if REAL_MAGICK="$real_magick" FAKE_MAGICK_MODE=partial-failure \
    PATH="$test_dir/bin:$PATH" "$cli" -i "$test_dir/input/scan.jpg" \
    -o "$failure_output" >/dev/null 2>&1; then
    printf '%s\n' 'expected partial ImageMagick failure to fail' >&2
    exit 1
fi
[[ ! -e $failure_output ]]
if REAL_MAGICK="$real_magick" FAKE_MAGICK_MODE=sleep \
    PATH="$test_dir/bin:$PATH" "$cli" -i "$test_dir/input/scan.jpg" \
    -o "$test_dir/timeout.jpg" --timeout 0.1s >/dev/null 2>&1; then
    printf '%s\n' 'expected ImageMagick timeout to fail' >&2
    exit 1
fi
[[ ! -e $test_dir/timeout.jpg ]]

metadata_source=$test_dir/metadata-source.jpg
metadata_output=$test_dir/metadata-output.jpg
cp "$test_dir/input/scan.jpg" "$metadata_source"
metadata_hash=$(shasum -a 256 <"$metadata_source")
metadata_size=$(stat -f '%z' "$metadata_source")
metadata_mtime=$(stat -f '%m' "$metadata_source")
metadata_ctime=$(stat -f '%c' "$metadata_source")
metadata_mode=$(stat -f '%Lp' "$metadata_source")
metadata_ready=$test_dir/metadata.ready
metadata_release=$test_dir/metadata.release
REAL_MAGICK="$real_magick" FAKE_MAGICK_READY_FILE="$metadata_ready" \
    FAKE_MAGICK_RELEASE_FILE="$metadata_release" PATH="$test_dir/bin:$PATH" \
    "$cli" -i "$metadata_source" -o "$metadata_output" \
    >"$test_dir/metadata.out" 2>"$test_dir/metadata.err" &
metadata_pid=$!
wait_for_file "$metadata_ready"
sleep 1.1
chmod u+x "$metadata_source"
chmod "$metadata_mode" "$metadata_source"
: >"$metadata_release"
wait "$metadata_pid"
[[ -s $metadata_output ]]
[[ $(shasum -a 256 <"$metadata_source") == "$metadata_hash" ]]
[[ $(stat -f '%z' "$metadata_source") == "$metadata_size" ]]
[[ $(stat -f '%m' "$metadata_source") == "$metadata_mtime" ]]
[[ $(stat -f '%c' "$metadata_source") != "$metadata_ctime" ]]

content_source=$test_dir/content-source.jpg
content_output=$test_dir/content-output.jpg
content_reference=$test_dir/content-reference
cp "$test_dir/input/scan.jpg" "$content_source"
touch -r "$content_source" "$content_reference"
content_hash=$(shasum -a 256 <"$content_source")
content_size=$(stat -f '%z' "$content_source")
content_mtime=$(stat -f '%m' "$content_source")
content_ctime=$(stat -f '%c' "$content_source")
content_ready=$test_dir/content.ready
content_release=$test_dir/content.release
REAL_MAGICK="$real_magick" FAKE_MAGICK_READY_FILE="$content_ready" \
    FAKE_MAGICK_RELEASE_FILE="$content_release" PATH="$test_dir/bin:$PATH" \
    "$cli" -i "$content_source" -o "$content_output" \
    >"$test_dir/content.out" 2>"$test_dir/content.err" &
content_pid=$!
wait_for_file "$content_ready"
sleep 1.1
printf 'X' | dd of="$content_source" bs=1 count=1 conv=notrunc 2>/dev/null
touch -r "$content_reference" "$content_source"
: >"$content_release"
set +o errexit
wait "$content_pid"
content_status=$?
set -o errexit
[[ $content_status -eq 1 ]]
[[ ! -e $content_output ]]
[[ $(stat -f '%z' "$content_source") == "$content_size" ]]
[[ $(stat -f '%m' "$content_source") == "$content_mtime" ]]
[[ $(stat -f '%c' "$content_source") != "$content_ctime" ]]
[[ $(shasum -a 256 <"$content_source") != "$content_hash" ]]

race_output=$test_dir/race.jpg
race_ready=$test_dir/race.ready
race_release=$test_dir/race.release
REAL_MAGICK="$real_magick" FAKE_MAGICK_READY_FILE="$race_ready" \
    FAKE_MAGICK_RELEASE_FILE="$race_release" PATH="$test_dir/bin:$PATH" \
    "$cli" -i "$test_dir/input/scan.jpg" -o "$race_output" \
    >"$test_dir/race.out" 2>"$test_dir/race.err" &
race_pid=$!
wait_for_file "$race_ready"
printf '%s\n' 'existing destination' >"$race_output"
: >"$race_release"
set +o errexit
wait "$race_pid"
race_status=$?
set -o errexit
[[ $race_status -eq 1 ]]
[[ $(sed -n '1p' "$race_output") == 'existing destination' ]]

signal_output=$test_dir/signal.jpg
signal_ready=$test_dir/signal.ready
signal_release=$test_dir/signal.release
REAL_MAGICK="$real_magick" FAKE_MAGICK_READY_FILE="$signal_ready" \
    FAKE_MAGICK_RELEASE_FILE="$signal_release" PATH="$test_dir/bin:$PATH" \
    "$cli" -i "$test_dir/input/scan.jpg" -o "$signal_output" \
    >"$test_dir/signal.out" 2>"$test_dir/signal.err" &
signal_pid=$!
wait_for_file "$signal_ready"
kill -TERM "$signal_pid"
set +o errexit
wait "$signal_pid"
signal_status=$?
set -o errexit
: >"$signal_release"
[[ $signal_status -eq 143 ]]
[[ ! -e $signal_output ]]

if find "$test_dir" -name '.scan-clean.*' -print | grep .; then
    printf '%s\n' 'temporary scan-clean output was not removed' >&2
    exit 1
fi

printf '%s\n' 'scan-clean command tests passed'
