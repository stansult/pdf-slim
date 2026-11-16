#!/usr/bin/env bash

set -o errexit
set -o nounset

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "$project_dir/.scan-clean-tone-tests.XXXXXX")
cli=$project_dir/scan-clean.sh
magick_command=$(command -v magick)

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

region_mean() {
    local image=$1
    local geometry=$2

    "$magick_command" "$image" -crop "$geometry" +repage -colorspace Gray \
        -format '%[fx:mean]' info:
}

region_rgb() {
    local image=$1
    local geometry=$2

    "$magick_command" "$image" -crop "$geometry" +repage \
        -format '%[fx:mean.r] %[fx:mean.g] %[fx:mean.b]' info:
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

assert_less_than() {
    local label=$1
    local left=$2
    local right=$3

    awk -v label="$label" -v left="$left" -v right="$right" 'BEGIN {
            if (left >= right) {
                printf "%s: expected %.6f to be less than %.6f\n", \
                    label, left, right > "/dev/stderr"
                exit 1
            }
        }'
}

assert_channel_spread_at_most() {
    local label=$1
    local values=$2
    local maximum_spread=$3

    awk -v label="$label" -v values="$values" \
        -v maximum_spread="$maximum_spread" 'BEGIN {
            split(values, channel, " ")
            minimum = maximum = channel[1]
            for (i = 2; i <= 3; i += 1) {
                if (channel[i] < minimum) minimum = channel[i]
                if (channel[i] > maximum) maximum = channel[i]
            }
            if (maximum - minimum > maximum_spread) {
                printf "%s: channel spread %.6f exceeds %.6f\n", label, \
                    maximum - minimum, maximum_spread > "/dev/stderr"
                exit 1
            }
        }'
}

gray_source=$test_dir/gray-paper.png
bright_source=$test_dir/bright-paper.png
blue_source=$test_dir/blue-paper.png

for fixture in "$gray_source:#e3e3e3" "$bright_source:#f1f1f1"; do
    destination=${fixture%%:*}
    background=${fixture#*:}
    "$magick_command" -size 120x100 "xc:$background" \
        -fill '#808080' -draw 'rectangle 25,25 95,40' \
        -fill '#a0a0a0' -stroke '#a0a0a0' -strokewidth 2 \
        -draw 'line 20,70 100,70' "$destination"
done

"$magick_command" -size 120x100 gradient:'#d5dce5-#e8edf2' -rotate 90 \
    -resize '120x100!' \
    -fill '#555b62' -draw 'rectangle 25,25 95,40' \
    -fill '#a02040' -draw 'rectangle 20,65 45,80' "$blue_source"

# Independently verify that the fixtures reach the intended tonal code paths.
assert_between 'gray fixture background' \
    "$(region_mean "$gray_source" '10x10+0+0')" 0.88 0.90
assert_between 'bright fixture background' \
    "$(region_mean "$bright_source" '10x10+0+0')" 0.93 0.96
assert_between 'gray fixture faint mark' \
    "$(region_mean "$gray_source" '80x2+20+70')" 0.67 0.70
assert_between 'gray fixture medium ink' \
    "$(region_mean "$gray_source" '60x10+30+28')" 0.49 0.51
awk -v values="$(region_rgb "$blue_source" '30x20+50+50')" 'BEGIN {
        split(values, channel, " ")
        if (channel[3] - channel[1] < 0.03) {
            print "blue fixture does not contain the intended cast" > "/dev/stderr"
            exit 1
        }
    }'

level_matrix=$(
    SCAN_CLEAN_TESTING=1 /bin/bash -c '
        source "$1"
        for PAPER_BRIGHTNESS_PERCENT in 50 89 94 100; do
            printf "%s:%s:%s:%s\n" "$PAPER_BRIGHTNESS_PERCENT" \
                "$(levels_for_mode gentle)" \
                "$(levels_for_mode standard)" \
                "$(levels_for_mode strong)"
        done
    ' _ "$cli"
)
expected_level_matrix=$'50:8%,90%:12%,88%:16%,86%\n89:8%,91%:12%,89%:16%,87%\n94:8%,96%:12%,94%:16%,92%\n100:8%,96%:12%,94%:16%,92%'
[[ $level_matrix == "$expected_level_matrix" ]]

"$cli" --input "$gray_source" --all-modes >/dev/null
"$cli" --input "$bright_source" --mode standard \
    --output "$test_dir/bright-standard.png" >/dev/null
"$cli" --input "$blue_source" --mode standard \
    --output "$test_dir/blue-standard.png" >/dev/null

gray_gentle=$test_dir/gray-paper-gentle.png
gray_standard=$test_dir/gray-paper-standard.png
gray_strong=$test_dir/gray-paper-strong.png
bright_standard=$test_dir/bright-standard.png
blue_standard=$test_dir/blue-standard.png

for output in "$gray_gentle" "$gray_standard" "$gray_strong" \
    "$bright_standard" "$blue_standard"; do
    [[ -s $output ]]
done

# Gray paper should approach white without materially changing already-white
# paper. Gentle retains a small tonal difference; standard and strong make the
# detected paper white.
assert_between 'gentle gray-paper background' \
    "$(region_mean "$gray_gentle" '10x10+0+0')" 0.96 1.00
assert_between 'standard gray-paper background' \
    "$(region_mean "$gray_standard" '10x10+0+0')" 0.99 1.00
assert_between 'strong gray-paper background' \
    "$(region_mean "$gray_strong" '10x10+0+0')" 0.99 1.00
assert_between 'standard bright-paper background' \
    "$(region_mean "$bright_standard" '10x10+0+0')" 0.99 1.00
assert_channel_spread_at_most 'standard blue-paper neutrality' \
    "$(region_rgb "$blue_standard" '30x20+50+50')" 0.015

# Dark ink must become progressively stronger across the three named modes.
gentle_ink=$(region_mean "$gray_gentle" '60x10+30+28')
standard_ink=$(region_mean "$gray_standard" '60x10+30+28')
strong_ink=$(region_mean "$gray_strong" '60x10+30+28')
assert_less_than 'standard ink versus gentle ink' "$standard_ink" "$gentle_ink"
assert_less_than 'strong ink versus standard ink' "$strong_ink" "$standard_ink"
assert_between 'standard medium-ink darkening' "$standard_ink" 0.30 0.42

# White balancing must retain an obviously colored annotation.
awk -v values="$(region_rgb "$blue_standard" '20x10+23+68')" 'BEGIN {
        split(values, channel, " ")
        if (channel[1] - channel[2] < 0.20 || \
            channel[1] - channel[3] < 0.20) {
            print "colored mark lost its red dominance" > "/dev/stderr"
            exit 1
        }
    }'

# A faint pencil-like mark must remain visible and distinct from the paper.
for output in "$gray_gentle" "$gray_standard" "$gray_strong"; do
    faint_mark=$(region_mean "$output" '80x2+20+70')
    background=$(region_mean "$output" '10x10+0+0')
    assert_between "faint mark retained in ${output##*/}" "$faint_mark" 0.25 0.90
    awk -v output="${output##*/}" -v background="$background" \
        -v faint_mark="$faint_mark" 'BEGIN {
            if (background - faint_mark < 0.15) {
                printf "%s: faint mark lacks paper contrast\n", output > "/dev/stderr"
                exit 1
            }
        }'
done

printf '%s\n' 'scan-clean tonal tests passed'
