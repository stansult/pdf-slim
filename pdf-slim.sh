#!/usr/bin/env bash

# Safe PDF size reduction and scan cleanup with explicit input/output modes,
# configurable image quality, reliable conversion, atomic publication,
# metadata preservation, replacement logging, and anonymous performance data.

set -o nounset

PROGRAM=${0##*/}
VERSION='1.4.0'
LOG_MAGIC='pdf-slim-log-v2'
LOG_MAGIC_V1='pdf-slim-log-v1'
LOG_WILDCARD_SIGNATURE='*'
CONVERSION_POLICY_REVISION='1'
DEFAULT_IMAGE_INPUT_DPI='300'
MINIMUM_CREDIBLE_IMAGE_DPI='150'
AUTOMATIC_SCAN_JOB_CAP='5'
PERFORMANCE_SCHEMA_VERSION='1'
PERFORMANCE_HEADER=$'schema_version\trecorded_at\tprogram_version\tos\toutcome\tfailure_stage\tcleanup_mode\tquality_policy\tsource_bytes\toutput_bytes\tpages\ttotal_pixels\tmin_page_pixels\tmedian_page_pixels\tmax_page_pixels\tcolor_pages\tgray_pages\tworker_selection\trequested_workers\teffective_workers\tmax_active_workers\tlogical_cpus\tphysical_cpus\tmemory_bytes\ttotal_seconds\tinspection_seconds\tcleanup_seconds\tpage_sum_seconds\tpage_min_seconds\tpage_median_seconds\tpage_max_seconds\tpage_times_seconds\tassembly_seconds\tghostscript_seconds'

LOG_RECORD_PATHS=()
LOG_RECORD_SIZES=()
LOG_RECORD_MTIMES=()
LOG_RECORD_SIGNATURES=()
LOG_RECORD_OUTCOMES=()
LOG_RECORD_TIMESTAMPS=()
LOG_RECORD_ARTIFACTS=()
PROCESS_OUTCOME=''
PROCESS_ARTIFACT=''
OPERATIONAL_OUTPUT_STARTED=0
OPERATIONAL_START_DATE=''
OPERATIONAL_LAST_STREAM='stderr'
VERBOSE=0
SOURCE_CHECK_IDENTITY=''
SOURCE_CHECK_METADATA_CHANGED=0
ACTIVE_SCAN_WORKERS=()
ACTIVE_METRICS_LOCK=''
METRICS_WARNING_EMITTED=0
METRICS_ACTIVE=0
METRIC_FAILURE_STAGE='-'
METRIC_PAGE_TIMES=()
METRIC_OS='-'
METRIC_LOGICAL_CPUS='-'
METRIC_PHYSICAL_CPUS='-'
METRIC_MEMORY_BYTES='-'
SCAN_IMAGE_WIDTH=()
SCAN_IMAGE_HEIGHT=()
SCAN_IMAGE_COLOR=()

usage() {
    cat <<EOF
pdf-slim.sh safely reduces PDF file sizes and converts cleaned document scans
from PDF or raster-image input into PDF output.
For image output, use scan-clean.sh.

Usage: $PROGRAM [options]

Input:
  -i, --input PATH    Input PDF, raster image with --clean-scan, directory, or
                      quoted glob pattern; repeat for multiple inputs

Exactly one output mode is required:
  -o, --output FILE   Write one input as PDF to exactly FILE
  --output-dir DIR    Preserve input-relative paths beneath DIR
  --replace           Replace originals only when safe conversion is smaller

Quality -- choose one approach:
  Preset:
    --quality MODE       Use preserve, balanced, or small
                         (default when no quality options are given: preserve)
  Detailed:
    --max-dpi DPI        Downsample color/grayscale images above DPI
                         (default: no color/grayscale DPI cap)
    --jpeg-recompress Q  JPEG-encode color/grayscale images at QFactor Q,
                         0.0-1.0; lower values preserve more quality
                         (default: existing eligible JPEGs pass through)
  --grayscale            Convert colors to grayscale; independent of either
                         quality approach

Do not combine --quality with --max-dpi or --jpeg-recompress.

Scan cleanup:
  --clean-scan [MODE]    Improve an image-only scan using gentle, standard, or
                         strong contrast cleanup while retaining color
                         (default mode: standard; with no quality options:
                         source DPI and JPEG QFactor 0.10; --grayscale remains
                         independent)
  --jobs N                Clean up to N PDF pages concurrently, 1-11
                          (default: automatic, up to 5; requires --clean-scan)

Options:
  --recursive         Descend into supplied directories
  --reprocess         Reprocess files that match the replacement log; all safety
                      checks remain enabled (requires --replace)
  --timeout DURATION  Per-file conversion timeout (default: 1h)
  --dry-run           Print planned actions; run no Ghostscript and write nothing
  -v, --verbose       Report resolved settings, stages, and scan performance
  --preserve-metadata MODE
                      Preserve none, basic, standard (default), or all metadata
  -h, --help          Show this help and exit
  --version           Show the version and exit

Examples:
  $PROGRAM -i report.pdf -o report-slim.pdf
  $PROGRAM -i scan.jpg -o scan-cleaned.pdf --clean-scan standard
  $PROGRAM -i documents --output-dir slimmed --recursive

Important:
  Exactly one output mode is required. --replace modifies an original only
  after successful validation and only when the result is smaller.
  Quote input glob patterns. Symlinks are skipped.
  Primary operational messages are prefixed with local [HH:MM:SS]; continuation
  lines remain unprefixed. The local date is printed before the first message
  and again after the last only if it changed.

Full documentation:
  https://github.com/stansult/pdf-slim

Exit status: 0 success, 1 conversion failure, 2 invalid or unsafe request.
EOF
}

usage_hint() {
    local text

    text=$(cat <<EOF
Choose how to handle converted PDFs. For the current directory:
  $PROGRAM --input . --output-dir slimmed
  $PROGRAM --input . --replace
For a single PDF:
  $PROGRAM --input original.pdf -o compressed.pdf
For a scanned image:
  $PROGRAM --input scan.jpg -o scan-cleaned.pdf --clean-scan standard

Run '$PROGRAM --help' for full usage.
EOF
)
    operational_continuation stderr "$text"
}

raw_output_line() {
    local stream=$1
    local line=$2

    if [[ $stream == stdout ]]; then
        printf '%s\n' "$line"
    else
        printf '%s\n' "$line" >&2
    fi
}

begin_operational_output() {
    local stream=$1

    if (( ! OPERATIONAL_OUTPUT_STARTED )); then
        OPERATIONAL_START_DATE=$(date '+%Y-%m-%d') || \
            OPERATIONAL_START_DATE='unknown-date'
        raw_output_line "$stream" "[$OPERATIONAL_START_DATE]"
        OPERATIONAL_OUTPUT_STARTED=1
    fi
    OPERATIONAL_LAST_STREAM=$stream
}

operational_block() {
    local stream=$1
    local text=$2
    local line current_time timestamp_written=0

    begin_operational_output "$stream"
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -z $line ]]; then
            raw_output_line "$stream" ''
            continue
        fi
        if (( ! timestamp_written )); then
            current_time=$(date '+%H:%M:%S') || current_time='??:??:??'
            raw_output_line "$stream" "[$current_time] $line"
            timestamp_written=1
        else
            raw_output_line "$stream" "$line"
        fi
    done <<< "$text"
}

operational_continuation() {
    local stream=$1
    local text=$2
    local line

    if (( ! OPERATIONAL_OUTPUT_STARTED )); then
        operational_block "$stream" "$text"
        return
    fi
    OPERATIONAL_LAST_STREAM=$stream
    while IFS= read -r line || [[ -n $line ]]; do
        raw_output_line "$stream" "$line"
    done <<< "$text"
}

operational_message() {
    local stream=$1
    local message=$2

    operational_block "$stream" "$message"
}

finish_operational_output() {
    local end_date

    (( OPERATIONAL_OUTPUT_STARTED )) || return 0
    end_date=$(date '+%Y-%m-%d') || end_date=$OPERATIONAL_START_DATE
    if [[ $end_date != "$OPERATIONAL_START_DATE" ]]; then
        raw_output_line "$OPERATIONAL_LAST_STREAM" "[$end_date]"
    fi
}

error() {
    operational_message stderr "$PROGRAM: error: $*"
}

warn() {
    operational_message stderr "$PROGRAM: warning: $*"
}

hint() {
    operational_continuation stderr "$PROGRAM: hint: $*"
}

verbose() {
    (( VERBOSE )) || return 0
    operational_message stderr "$PROGRAM: verbose: $*"
}

expand_input_pattern() (
    local pattern=$1
    local IFS=
    local -a matches=()

    set +o noglob
    shopt -s nullglob
    shopt -u failglob dotglob nocaseglob
    # Word splitting is disabled by the empty IFS; pathname expansion is
    # intentionally enabled here so matches remain separate array elements.
    # shellcheck disable=SC2206
    matches=( $pattern )
    (( ${#matches[@]} )) && printf '%s\0' "${matches[@]}"
)

find_command() {
    local candidate

    for candidate in "$@"; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    return 1
}

find_scan_clean_command() {
    local script_path=$1
    local sibling=${script_path%/*}/scan-clean.sh
    local command_path

    if [[ -f $sibling && -x $sibling ]]; then
        realpath -- "$sibling"
        return
    fi
    command_path=$(find_command scan-clean.sh) || return 1
    [[ -f $command_path && -x $command_path ]] || return 1
    realpath -- "$command_path"
}

remove_candidate() {
    local candidate=$1

    if [[ -n $candidate && ( -e $candidate || -L $candidate ) ]]; then
        rm -f -- "$candidate"
    fi
}

file_mode() {
    stat -f '%Lp' -- "$1" 2>/dev/null || stat -c '%a' -- "$1"
}

file_size() {
    stat -f '%z' -- "$1" 2>/dev/null || stat -c '%s' -- "$1"
}

file_identity() {
    stat -f '%d:%i:%z:%m:%c' -- "$1" 2>/dev/null || \
        stat -c '%d:%i:%s:%Y:%Z' -- "$1"
}

file_fingerprint() {
    local output fingerprint

    if command -v shasum >/dev/null 2>&1; then
        output=$(shasum -a 256 <"$1") || return 1
    elif command -v sha256sum >/dev/null 2>&1; then
        output=$(sha256sum <"$1") || return 1
    elif command -v openssl >/dev/null 2>&1; then
        output=$(openssl dgst -sha256 -r <"$1") || return 1
    else
        return 1
    fi
    fingerprint=${output%% *}
    [[ $fingerprint =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    printf '%s\n' "$fingerprint"
}

verify_source_unchanged() {
    local source=$1
    local expected_identity=$2
    local expected_content_identity=$3
    local expected_fingerprint=$4
    local timing=$5
    local current_identity current_content_identity current_fingerprint

    SOURCE_CHECK_IDENTITY=''
    SOURCE_CHECK_METADATA_CHANGED=0
    current_identity=$(file_identity "$source") || current_identity='missing'
    if [[ $current_identity == "$expected_identity" ]]; then
        SOURCE_CHECK_IDENTITY=$current_identity
        return 0
    fi
    current_content_identity=${current_identity%:*}
    if [[ $current_identity == missing || \
        $current_content_identity != "$expected_content_identity" ]]; then
        error "source changed $timing; leaving it untouched: $source"
        return 1
    fi
    current_fingerprint=$(file_fingerprint "$source") || {
        error "could not verify source content $timing: $source"
        return 1
    }
    if [[ $current_fingerprint != "$expected_fingerprint" ]]; then
        error "source changed $timing; leaving it untouched: $source"
        return 1
    fi
    SOURCE_CHECK_IDENTITY=$current_identity
    SOURCE_CHECK_METADATA_CHANGED=1
    verbose "source metadata changed $timing; SHA-256 content is unchanged: $source"
}

file_times() {
    stat -f '%a:%m' -- "$1" 2>/dev/null || stat -c '%X:%Y' -- "$1"
}

file_mtime() {
    stat -f '%m' -- "$1" 2>/dev/null || stat -c '%Y' -- "$1"
}

replacement_state_directory() {
    local state_directory
    local system_name

    if [[ -n ${PDF_SLIM_STATE_DIR:-} ]]; then
        state_directory=$PDF_SLIM_STATE_DIR
    else
        if [[ -z ${HOME:-} ]]; then
            error 'HOME is required to locate replacement history'
            return 1
        fi
        system_name=$(uname -s) || return 1
        if [[ $system_name == Darwin ]]; then
            state_directory=$HOME/Library/Application\ Support/pdf-slim
        else
            state_directory=${XDG_STATE_HOME:-$HOME/.local/state}/pdf-slim
        fi
    fi
    if [[ $state_directory != /* ]]; then
        error "replacement state directory must be an absolute path: $state_directory"
        return 1
    fi
    printf '%s\n' "$state_directory"
}

ensure_replacement_state_directory() {
    local state_directory=$1
    local old_umask status

    if [[ -L $state_directory ]]; then
        error "replacement state directory must not be a symlink: $state_directory"
        return 1
    fi
    if [[ -e $state_directory && ! -d $state_directory ]]; then
        error "replacement state path is not a directory: $state_directory"
        return 1
    fi
    if [[ ! -d $state_directory ]]; then
        old_umask=$(umask)
        umask 077
        mkdir -p -- "$state_directory"
        status=$?
        umask "$old_umask"
        if (( status != 0 )); then
            error "could not create replacement state directory: $state_directory"
            return 1
        fi
    fi
    chmod 700 "$state_directory" || {
        error "could not secure replacement state directory: $state_directory"
        return 1
    }
}

metrics_state_directory() {
    local system_name

    if [[ -n ${PDF_SLIM_STATE_DIR:-} ]]; then
        [[ $PDF_SLIM_STATE_DIR == /* ]] || return 1
        printf '%s\n' "$PDF_SLIM_STATE_DIR"
        return 0
    fi
    [[ -n ${HOME:-} ]] || return 1
    system_name=$(uname -s 2>/dev/null) || return 1
    if [[ $system_name == Darwin ]]; then
        printf '%s\n' "$HOME/Library/Application Support/pdf-slim"
    else
        printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/pdf-slim"
    fi
}

ensure_metrics_state_directory() {
    local state_directory=$1
    local old_umask status

    [[ ! -L $state_directory ]] || return 1
    [[ ! -e $state_directory || -d $state_directory ]] || return 1
    if [[ ! -d $state_directory ]]; then
        old_umask=$(umask)
        umask 077
        mkdir -p -- "$state_directory"
        status=$?
        umask "$old_umask"
        (( status == 0 )) || return 1
    fi
    chmod 700 "$state_directory" >/dev/null 2>&1
}

acquire_metrics_lock() {
    local metrics_file=$1
    local lock_dir=$metrics_file.lock
    local attempts=0

    while ! mkdir "$lock_dir" 2>/dev/null; do
        ((attempts += 1))
        (( attempts < 20 )) || return 1
        sleep 0.1
    done
    ACTIVE_METRICS_LOCK=$lock_dir
}

release_metrics_lock() {
    if [[ -n $ACTIVE_METRICS_LOCK ]]; then
        rmdir "$ACTIVE_METRICS_LOCK" 2>/dev/null || true
        ACTIVE_METRICS_LOCK=''
    fi
}

metrics_warning() {
    (( METRICS_WARNING_EMITTED == 0 )) || return 0
    METRICS_WARNING_EMITTED=1
    warn 'could not record scan-clean performance metrics; conversion results are unaffected'
}

append_performance_record() {
    local record=$1
    local state_directory metrics_file existing_header old_umask status=0

    state_directory=$(metrics_state_directory) || return 1
    ensure_metrics_state_directory "$state_directory" || return 1
    metrics_file=$state_directory/performance.tsv
    acquire_metrics_lock "$metrics_file" || return 1
    if [[ -L $metrics_file || ( -e $metrics_file && ! -f $metrics_file ) ]]; then
        release_metrics_lock
        return 1
    fi
    if [[ ! -e $metrics_file ]]; then
        old_umask=$(umask)
        umask 077
        printf '%s\n' "$PERFORMANCE_HEADER" >"$metrics_file" || status=1
        umask "$old_umask"
    else
        IFS= read -r existing_header <"$metrics_file" || status=1
        [[ $existing_header == "$PERFORMANCE_HEADER" ]] || status=1
    fi
    if (( status == 0 )); then
        chmod 600 "$metrics_file" >/dev/null 2>&1 || status=1
    fi
    if (( status == 0 )); then
        printf '%s\n' "$record" >>"$metrics_file" || status=1
    fi
    release_metrics_lock
    (( status == 0 ))
}

detect_metrics_machine() {
    local system_name

    METRIC_OS=$(uname -s 2>/dev/null || printf '%s' '-')
    METRIC_LOGICAL_CPUS='-'
    METRIC_PHYSICAL_CPUS='-'
    METRIC_MEMORY_BYTES='-'
    system_name=$METRIC_OS
    if [[ $system_name == Darwin ]]; then
        METRIC_LOGICAL_CPUS=$(sysctl -n hw.logicalcpu 2>/dev/null || printf '%s' '-')
        METRIC_PHYSICAL_CPUS=$(sysctl -n hw.physicalcpu 2>/dev/null || printf '%s' '-')
        METRIC_MEMORY_BYTES=$(sysctl -n hw.memsize 2>/dev/null || printf '%s' '-')
    else
        METRIC_LOGICAL_CPUS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s' '-')
        if [[ -r /proc/meminfo ]]; then
            METRIC_MEMORY_BYTES=$(awk '/^MemTotal:/ { print $2 * 1024; exit }' \
                /proc/meminfo 2>/dev/null || printf '%s' '-')
        fi
    fi
}

metrics_median() {
    local count middle left right value
    local -a sorted=()

    (( $# )) || { printf '%s\n' '-'; return; }
    while IFS= read -r value; do
        sorted[${#sorted[@]}]=$value
    done < <(printf '%s\n' "$@" | LC_ALL=C sort -n)
    count=${#sorted[@]}
    middle=$((count / 2))
    if (( count % 2 )); then
        printf '%s\n' "${sorted[$middle]}"
    else
        left=${sorted[$((middle - 1))]}
        right=${sorted[$middle]}
        printf '%s\n' "$(((left + right) / 2))"
    fi
}

reset_performance_metrics() {
    METRICS_ACTIVE=1
    METRIC_START_SECONDS=$SECONDS
    METRIC_RECORDED_AT=$(date +%s 2>/dev/null || printf '%s' '-')
    METRIC_OUTCOME='failed'
    METRIC_FAILURE_STAGE='setup'
    METRIC_SOURCE_BYTES='-'
    METRIC_OUTPUT_BYTES='-'
    METRIC_PAGES='-'
    METRIC_TOTAL_PIXELS='-'
    METRIC_MIN_PAGE_PIXELS='-'
    METRIC_MEDIAN_PAGE_PIXELS='-'
    METRIC_MAX_PAGE_PIXELS='-'
    METRIC_COLOR_PAGES='-'
    METRIC_GRAY_PAGES='-'
    METRIC_WORKER_SELECTION=auto
    METRIC_REQUESTED_WORKERS='-'
    METRIC_EFFECTIVE_WORKERS='-'
    METRIC_MAX_ACTIVE_WORKERS='-'
    METRIC_TOTAL_SECONDS='-'
    METRIC_INSPECTION_SECONDS='-'
    METRIC_CLEANUP_SECONDS='-'
    METRIC_PAGE_SUM_SECONDS='-'
    METRIC_PAGE_MIN_SECONDS='-'
    METRIC_PAGE_MEDIAN_SECONDS='-'
    METRIC_PAGE_MAX_SECONDS='-'
    METRIC_PAGE_TIMES_TEXT='-'
    METRIC_ASSEMBLY_SECONDS='-'
    METRIC_GHOSTSCRIPT_SECONDS='-'
    METRIC_PAGE_TIMES=()
    if [[ ${jobs:-auto} != auto ]]; then
        METRIC_WORKER_SELECTION=explicit
        METRIC_REQUESTED_WORKERS=$jobs
    fi
}

collect_scan_shape_metrics() {
    local page pixels total=0 color_pages=0 gray_pages=0
    local -a page_pixels=()

    METRIC_PAGES=$SCAN_PAGE_COUNT
    for (( page = 1; page <= SCAN_PAGE_COUNT; page += 1 )); do
        pixels=$((${SCAN_IMAGE_WIDTH[$page]} * ${SCAN_IMAGE_HEIGHT[$page]}))
        page_pixels[${#page_pixels[@]}]=$pixels
        total=$((total + pixels))
        case ${SCAN_IMAGE_COLOR[$page]} in
            gray|mono) gray_pages=$((gray_pages + 1)) ;;
            *) color_pages=$((color_pages + 1)) ;;
        esac
    done
    METRIC_TOTAL_PIXELS=$total
    METRIC_MIN_PAGE_PIXELS=$(printf '%s\n' "${page_pixels[@]}" | \
        LC_ALL=C sort -n | sed -n '1p')
    METRIC_MAX_PAGE_PIXELS=$(printf '%s\n' "${page_pixels[@]}" | \
        LC_ALL=C sort -n | tail -n 1)
    METRIC_MEDIAN_PAGE_PIXELS=$(metrics_median "${page_pixels[@]}")
    METRIC_COLOR_PAGES=$color_pages
    METRIC_GRAY_PAGES=$gray_pages
}

summarize_page_metrics() {
    local duration sum=0 text=''
    local -a available=()

    for duration in "${METRIC_PAGE_TIMES[@]}"; do
        [[ $duration =~ ^[0-9]+$ ]] || continue
        available[${#available[@]}]=$duration
        sum=$((sum + duration))
        if [[ -n $text ]]; then
            text=$text,$duration
        else
            text=$duration
        fi
    done
    (( ${#available[@]} )) || return 0
    METRIC_PAGE_SUM_SECONDS=$sum
    METRIC_PAGE_MIN_SECONDS=$(printf '%s\n' "${available[@]}" | \
        LC_ALL=C sort -n | sed -n '1p')
    METRIC_PAGE_MAX_SECONDS=$(printf '%s\n' "${available[@]}" | \
        LC_ALL=C sort -n | tail -n 1)
    METRIC_PAGE_MEDIAN_SECONDS=$(metrics_median "${available[@]}")
    METRIC_PAGE_TIMES_TEXT=$text
}

performance_quality_policy() {
    printf 'quality=%s,max-dpi=%s,jpeg=%s,grayscale=%s' \
        "$quality" "${max_dpi:-none}" "${jpeg_recompress:-pass-through}" \
        "$grayscale"
}

format_metric_pixels() {
    awk -v value="$1" 'BEGIN {
        if (value >= 1000000) printf "%.1fMP", value / 1000000
        else printf "%dpx", value
    }'
}

format_metric_bytes() {
    awk -v value="$1" 'BEGIN {
        if (value >= 1048576) printf "%.1fMiB", value / 1048576
        else if (value >= 1024) printf "%.1fKiB", value / 1024
        else printf "%dB", value
    }'
}

finish_performance_metrics() {
    local status=$1
    local quality_policy record summary display_value

    METRIC_TOTAL_SECONDS=$((SECONDS - METRIC_START_SECONDS))
    summarize_page_metrics
    if (( status == 0 )); then
        METRIC_OUTCOME=success
        METRIC_FAILURE_STAGE='-'
    fi
    quality_policy=$(performance_quality_policy)
    record=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$PERFORMANCE_SCHEMA_VERSION" "$METRIC_RECORDED_AT" "$VERSION" \
        "$METRIC_OS" "$METRIC_OUTCOME" "$METRIC_FAILURE_STAGE" \
        "$clean_scan" "$quality_policy" "$METRIC_SOURCE_BYTES" \
        "$METRIC_OUTPUT_BYTES" "$METRIC_PAGES" "$METRIC_TOTAL_PIXELS" \
        "$METRIC_MIN_PAGE_PIXELS" "$METRIC_MEDIAN_PAGE_PIXELS" \
        "$METRIC_MAX_PAGE_PIXELS" "$METRIC_COLOR_PAGES" \
        "$METRIC_GRAY_PAGES" "$METRIC_WORKER_SELECTION" \
        "$METRIC_REQUESTED_WORKERS" "$METRIC_EFFECTIVE_WORKERS" \
        "$METRIC_MAX_ACTIVE_WORKERS" "$METRIC_LOGICAL_CPUS" \
        "$METRIC_PHYSICAL_CPUS" "$METRIC_MEMORY_BYTES" \
        "$METRIC_TOTAL_SECONDS" "$METRIC_INSPECTION_SECONDS" \
        "$METRIC_CLEANUP_SECONDS" "$METRIC_PAGE_SUM_SECONDS" \
        "$METRIC_PAGE_MIN_SECONDS" "$METRIC_PAGE_MEDIAN_SECONDS" \
        "$METRIC_PAGE_MAX_SECONDS" "$METRIC_PAGE_TIMES_TEXT" \
        "$METRIC_ASSEMBLY_SECONDS" "$METRIC_GHOSTSCRIPT_SECONDS")
    # Prevent signal cleanup from trying to finalize the same attempt again
    # while its record is being appended.
    METRICS_ACTIVE=0
    append_performance_record "$record" || metrics_warning
    summary="metrics: $METRIC_OUTCOME"
    [[ $METRIC_FAILURE_STAGE == - ]] || \
        summary="$summary stage=$METRIC_FAILURE_STAGE"
    [[ $METRIC_PAGES == - ]] || summary="$summary pages=$METRIC_PAGES"
    [[ $METRIC_EFFECTIVE_WORKERS == - ]] || \
        summary="$summary workers=$METRIC_EFFECTIVE_WORKERS($METRIC_WORKER_SELECTION)"
    if [[ $METRIC_TOTAL_PIXELS != - ]]; then
        display_value=$(format_metric_pixels "$METRIC_TOTAL_PIXELS")
        summary="$summary pixels=$display_value"
    fi
    [[ $METRIC_PAGE_MIN_SECONDS == - ]] || \
        summary="$summary page-time=$METRIC_PAGE_MIN_SECONDS/$METRIC_PAGE_MEDIAN_SECONDS/${METRIC_PAGE_MAX_SECONDS}s"
    [[ $METRIC_CLEANUP_SECONDS == - ]] || \
        summary="$summary cleanup=${METRIC_CLEANUP_SECONDS}s"
    summary="$summary total=${METRIC_TOTAL_SECONDS}s"
    if [[ $METRIC_OUTPUT_BYTES != - ]]; then
        display_value=$(format_metric_bytes "$METRIC_OUTPUT_BYTES")
        summary="$summary output=$display_value"
    fi
    verbose "$summary"
}

processing_signature() {
    local quality=$1
    local max_dpi=$2
    local jpeg_recompress=$3
    local grayscale=$4
    local clean_scan=$5
    local metadata_mode=$6
    local normalized_jpeg=$jpeg_recompress

    if [[ -n $normalized_jpeg && $normalized_jpeg == *.* ]]; then
        while [[ $normalized_jpeg == *0 ]]; do
            normalized_jpeg=${normalized_jpeg%0}
        done
        normalized_jpeg=${normalized_jpeg%.}
    fi

    printf 'policy=%s;quality=%s;max-dpi=%s;jpeg=%s;grayscale=%s;clean-scan=%s;metadata=%s\n' \
        "$CONVERSION_POLICY_REVISION" "$quality" "${max_dpi:-none}" \
        "${normalized_jpeg:-pass-through}" "$grayscale" \
        "${clean_scan:-none}" "$metadata_mode"
}

acquire_log_lock() {
    local log_file=$1
    local lock_dir=$log_file.lock
    local attempts=0

    while ! mkdir "$lock_dir" 2>/dev/null; do
        ((attempts += 1))
        if (( attempts >= 50 )); then
            error "could not acquire replacement-log lock: $lock_dir"
            return 1
        fi
        sleep 0.1
    done
    ACTIVE_LOG_LOCK=$lock_dir
}

release_log_lock() {
    if [[ -n ${ACTIVE_LOG_LOCK:-} ]]; then
        rmdir "$ACTIVE_LOG_LOCK" 2>/dev/null || true
        ACTIVE_LOG_LOCK=''
    fi
}

replacement_log_header() {
    local log_file=$1
    local header

    if [[ -L $log_file || ! -f $log_file ]]; then
        error "replacement log is not a regular file: $log_file"
        return 1
    fi
    IFS= read -r -d '' header <"$log_file" || {
        error "replacement log has an invalid header: $log_file"
        return 1
    }
    if [[ $header != "$LOG_MAGIC" && $header != "$LOG_MAGIC_V1" ]]; then
        error "replacement log uses an unsupported format: $log_file"
        return 1
    fi
    printf '%s\n' "$header"
}

ensure_replacement_log() {
    local log_file=$1
    local state_directory=${log_file%/*}
    local old_umask status

    if [[ -e $log_file || -L $log_file ]]; then
        [[ $(replacement_log_header "$log_file") == "$LOG_MAGIC" ]]
        return
    fi
    ensure_replacement_state_directory "$state_directory" || return 1
    old_umask=$(umask)
    umask 077
    printf '%s\0' "$LOG_MAGIC" >"$log_file"
    status=$?
    umask "$old_umask"
    (( status == 0 )) || {
        error "could not create replacement log: $log_file"
        return 1
    }
}

load_replacement_log() {
    local log_file=$1
    local header record_path record_size record_mtime record_signature
    local record_outcome record_timestamp record_artifact incomplete=0

    LOG_RECORD_PATHS=()
    LOG_RECORD_SIZES=()
    LOG_RECORD_MTIMES=()
    LOG_RECORD_SIGNATURES=()
    LOG_RECORD_OUTCOMES=()
    LOG_RECORD_TIMESTAMPS=()
    LOG_RECORD_ARTIFACTS=()
    [[ -e $log_file || -L $log_file ]] || return 0

    acquire_log_lock "$log_file" || return 1
    header=$(replacement_log_header "$log_file") || {
        release_log_lock
        return 1
    }
    exec 3<"$log_file" || {
        release_log_lock
        return 1
    }
    IFS= read -r -d '' header <&3 || incomplete=1
    while (( ! incomplete )) && IFS= read -r -d '' record_path <&3; do
        IFS= read -r -d '' record_size <&3 || { incomplete=1; break; }
        IFS= read -r -d '' record_mtime <&3 || { incomplete=1; break; }
        if [[ $header == "$LOG_MAGIC" ]]; then
            IFS= read -r -d '' record_signature <&3 || { incomplete=1; break; }
            IFS= read -r -d '' record_outcome <&3 || { incomplete=1; break; }
            IFS= read -r -d '' record_timestamp <&3 || { incomplete=1; break; }
            IFS= read -r -d '' record_artifact <&3 || { incomplete=1; break; }
        else
            record_signature=$LOG_WILDCARD_SIGNATURE
            record_outcome='v1-import'
            record_timestamp=''
            record_artifact=''
        fi
        LOG_RECORD_PATHS[${#LOG_RECORD_PATHS[@]}]=$record_path
        LOG_RECORD_SIZES[${#LOG_RECORD_SIZES[@]}]=$record_size
        LOG_RECORD_MTIMES[${#LOG_RECORD_MTIMES[@]}]=$record_mtime
        LOG_RECORD_SIGNATURES[${#LOG_RECORD_SIGNATURES[@]}]=$record_signature
        LOG_RECORD_OUTCOMES[${#LOG_RECORD_OUTCOMES[@]}]=$record_outcome
        LOG_RECORD_TIMESTAMPS[${#LOG_RECORD_TIMESTAMPS[@]}]=$record_timestamp
        LOG_RECORD_ARTIFACTS[${#LOG_RECORD_ARTIFACTS[@]}]=$record_artifact
    done
    exec 3<&-
    release_log_lock
    if (( incomplete )); then
        error "replacement log contains an incomplete record: $log_file"
        return 1
    fi
}

write_loaded_replacement_log() {
    local log_file=$1
    local state_directory=${log_file%/*}
    local temporary_log old_umask status=0 i

    ensure_replacement_state_directory "$state_directory" || return 1
    temporary_log=$(mktemp "$state_directory/.pdf-slim-log.XXXXXX") || {
        error "could not create replacement-log migration file: $state_directory"
        return 1
    }
    old_umask=$(umask)
    umask 077
    printf '%s\0' "$LOG_MAGIC" >"$temporary_log" || status=1
    i=0
    while (( status == 0 && i < ${#LOG_RECORD_PATHS[@]} )); do
        printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
            "${LOG_RECORD_PATHS[$i]}" "${LOG_RECORD_SIZES[$i]}" \
            "${LOG_RECORD_MTIMES[$i]}" "${LOG_RECORD_SIGNATURES[$i]}" \
            "${LOG_RECORD_OUTCOMES[$i]}" "${LOG_RECORD_TIMESTAMPS[$i]}" \
            "${LOG_RECORD_ARTIFACTS[$i]}" >>"$temporary_log" || status=1
        ((i += 1))
    done
    umask "$old_umask"
    if (( status != 0 )); then
        rm -f -- "$temporary_log"
        error "could not write migrated replacement log: $log_file"
        return 1
    fi
    chmod 600 "$temporary_log" || {
        rm -f -- "$temporary_log"
        error "could not secure migrated replacement log: $log_file"
        return 1
    }
    acquire_log_lock "$log_file" || {
        rm -f -- "$temporary_log"
        return 1
    }
    mv -f -- "$temporary_log" "$log_file" || {
        release_log_lock
        rm -f -- "$temporary_log"
        error "could not publish migrated replacement log: $log_file"
        return 1
    }
    release_log_lock
}

migrate_replacement_log() {
    local source_log=$1
    local destination_log=$2
    local source_header

    [[ -e $source_log || -L $source_log ]] || return 0
    source_header=$(replacement_log_header "$source_log") || return 1
    if [[ $source_log == "$destination_log" && $source_header == "$LOG_MAGIC" ]]; then
        load_replacement_log "$source_log"
        return
    fi
    if [[ $source_log != "$destination_log" && \
        ( -e $destination_log || -L $destination_log ) ]]; then
        return 0
    fi
    load_replacement_log "$source_log" || return 1
    write_loaded_replacement_log "$destination_log" || return 1
    operational_message stdout \
        "migrated replacement history: $destination_log"
}

append_replacement_log() {
    local log_file=$1
    local source=$2
    local signature=$3
    local outcome=$4
    local artifact=${5:-}
    local canonical size mtime processed_at

    canonical=$(realpath -- "$source") || return 1
    size=$(file_size "$source") || return 1
    mtime=$(file_mtime "$source") || return 1
    processed_at=$(date +%s) || return 1
    ensure_replacement_state_directory "${log_file%/*}" || return 1
    acquire_log_lock "$log_file" || return 1
    if ! ensure_replacement_log "$log_file"; then
        release_log_lock
        return 1
    fi
    if ! printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
        "$canonical" "$size" "$mtime" "$signature" "$outcome" \
        "$processed_at" "$artifact" >>"$log_file"; then
        error "could not append replacement log: $log_file"
        release_log_lock
        return 1
    fi
    release_log_lock
}

filter_logged_sources() {
    local log_file=$1
    local signature=$2
    local i j canonical size mtime matched
    local -a kept_sources=()
    local -a kept_source_keys=()
    local -a kept_relatives=()
    local -a kept_source_types=()

    [[ -e $log_file || -L $log_file ]] || return 0
    load_replacement_log "$log_file" || return 1
    i=0
    while (( i < ${#sources[@]} )); do
        canonical=$(realpath -- "${sources[$i]}") || return 1
        size=$(file_size "${sources[$i]}") || return 1
        mtime=$(file_mtime "${sources[$i]}") || return 1
        matched=0
        j=0
        while (( j < ${#LOG_RECORD_PATHS[@]} )); do
            if [[ ${LOG_RECORD_PATHS[$j]} == "$canonical" && \
                ${LOG_RECORD_SIZES[$j]} == "$size" && \
                ${LOG_RECORD_MTIMES[$j]} == "$mtime" && \
                ( ${LOG_RECORD_SIGNATURES[$j]} == "$signature" || \
                ${LOG_RECORD_SIGNATURES[$j]} == "$LOG_WILDCARD_SIGNATURE" ) ]]; then
                matched=1
                break
            fi
            ((j += 1))
        done
        if (( matched )); then
            operational_message stdout \
                "skipped unchanged file recorded as processed: ${sources[$i]}"
        else
            kept_sources[${#kept_sources[@]}]=${sources[$i]}
            kept_source_keys[${#kept_source_keys[@]}]=${source_keys[$i]}
            kept_relatives[${#kept_relatives[@]}]=${relatives[$i]}
            kept_source_types[${#kept_source_types[@]}]=${source_types[$i]}
        fi
        ((i += 1))
    done
    sources=("${kept_sources[@]}")
    source_keys=("${kept_source_keys[@]}")
    relatives=("${kept_relatives[@]}")
    source_types=("${kept_source_types[@]}")
}

prepare_candidate_metadata() {
    local source=$1
    local candidate=$2
    local metadata_mode=$3
    local mode_bits

    case $metadata_mode in
        none) return 0 ;;
        basic|standard)
            mode_bits=$(file_mode "$source") || return 1
            chmod "$mode_bits" "$candidate"
            ;;
        all)
            # macOS cp preserves mode, ownership where permitted, timestamps,
            # ACLs, file flags, and extended attributes unless -X is supplied.
            cp -p "$source" "$candidate" || return 1
            : >"$candidate"
            ;;
    esac
}

verify_all_metadata() {
    local source=$1
    local candidate=$2
    local source_stat candidate_stat source_attrs candidate_attrs attribute
    local source_value candidate_value source_acl candidate_acl

    if [[ $(uname -s) != Darwin ]]; then
        error '--preserve-metadata all is currently supported only on macOS'
        return 1
    fi
    command -v xattr >/dev/null 2>&1 || {
        error 'xattr is required for --preserve-metadata all'
        return 1
    }

    source_stat=$(stat -f '%u:%g:%Lp:%f' -- "$source") || return 1
    candidate_stat=$(stat -f '%u:%g:%Lp:%f' -- "$candidate") || return 1
    if [[ $source_stat != "$candidate_stat" ]]; then
        error "ownership or permissions could not be preserved: $source"
        return 1
    fi

    source_attrs=$(xattr "$source") || return 1
    candidate_attrs=$(xattr "$candidate") || return 1
    if [[ $source_attrs != "$candidate_attrs" ]]; then
        error "extended attributes could not be preserved: $source"
        return 1
    fi
    while IFS= read -r attribute; do
        [[ -n $attribute ]] || continue
        source_value=$(xattr -px "$attribute" "$source") || return 1
        candidate_value=$(xattr -px "$attribute" "$candidate") || return 1
        if [[ $source_value != "$candidate_value" ]]; then
            error "extended attribute could not be preserved ($attribute): $source"
            return 1
        fi
    done <<<"$source_attrs"

    source_acl=$(ls -lde "$source") || return 1
    candidate_acl=$(ls -lde "$candidate") || return 1
    if [[ $source_acl == *$'\n'* ]]; then
        source_acl=${source_acl#*$'\n'}
    else
        source_acl=''
    fi
    if [[ $candidate_acl == *$'\n'* ]]; then
        candidate_acl=${candidate_acl#*$'\n'}
    else
        candidate_acl=''
    fi
    if [[ $source_acl != "$candidate_acl" ]]; then
        error "ACL could not be preserved: $source"
        return 1
    fi
}

finalize_candidate_metadata() {
    local source=$1
    local candidate=$2
    local metadata_mode=$3
    local timestamp_reference=$4
    local mode_bits candidate_mode source_times candidate_times

    case $metadata_mode in
        none) return 0 ;;
        basic)
            mode_bits=$(file_mode "$source") || return 1
            chmod "$mode_bits" "$candidate" || return 1
            candidate_mode=$(file_mode "$candidate") || return 1
            [[ $candidate_mode == "$mode_bits" ]]
            ;;
        standard)
            mode_bits=$(file_mode "$source") || return 1
            chmod "$mode_bits" "$candidate" || return 1
            touch -r "$timestamp_reference" "$candidate" || return 1
            candidate_mode=$(file_mode "$candidate") || return 1
            source_times=$(file_times "$timestamp_reference") || return 1
            candidate_times=$(file_times "$candidate") || return 1
            [[ $candidate_mode == "$mode_bits" && $candidate_times == "$source_times" ]]
            ;;
        all)
            touch -r "$timestamp_reference" "$candidate" || return 1
            source_times=$(file_times "$timestamp_reference") || return 1
            candidate_times=$(file_times "$candidate") || return 1
            [[ $candidate_times == "$source_times" ]] || return 1
            verify_all_metadata "$source" "$candidate"
            ;;
    esac
}

ensure_output_parent() {
    local relative=$1
    local parent=${relative%/*}
    local current=$output_dir
    local component

    if [[ $parent == "$relative" ]]; then
        parent=''
    fi
    if [[ -L $current ]]; then
        error "output directory must not be a symlink: $current"
        return 1
    fi
    mkdir -p "$current" || return 1

    while [[ -n $parent ]]; do
        if [[ $parent == */* ]]; then
            component=${parent%%/*}
            parent=${parent#*/}
        else
            component=$parent
            parent=''
        fi
        [[ -n $component && $component != . ]] || continue
        if [[ $component == .. ]]; then
            error "unsafe output-relative path: $relative"
            return 1
        fi
        current=$current/$component
        if [[ -L $current ]]; then
            error "refusing symlink in output path: $current"
            return 1
        fi
        if [[ -e $current && ! -d $current ]]; then
            error "output parent is not a directory: $current"
            return 1
        fi
        [[ -d $current ]] || mkdir "$current" || return 1
    done
}

remove_scan_directory() {
    local directory=$1

    [[ -n $directory ]] || return 0
    if [[ ${directory##*/} != pdf-slim-scan.* ]]; then
        error "refusing to remove unexpected scan temporary directory: $directory"
        return 1
    fi
    if [[ -e $directory || -L $directory ]]; then
        rm -rf -- "$directory"
    fi
}

remove_active_scan_worker() {
    local completed_pid=$1
    local pid
    local -a remaining=()

    for pid in "${ACTIVE_SCAN_WORKERS[@]}"; do
        [[ $pid == "$completed_pid" ]] || remaining[${#remaining[@]}]=$pid
    done
    ACTIVE_SCAN_WORKERS=( "${remaining[@]}" )
}

stop_active_scan_workers() {
    local pid

    for pid in "${ACTIVE_SCAN_WORKERS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${ACTIVE_SCAN_WORKERS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    ACTIVE_SCAN_WORKERS=()
}

run_scan_command() {
    local stage=$1
    local source=$2
    local timeout_command=$3
    local timeout_duration=$4
    local status
    shift 4

    SCAN_COMMAND_OUTPUT=$("$timeout_command" -- "$timeout_duration" "$@" 2>&1)
    status=$?
    if (( status == 0 )); then
        return 0
    fi
    if (( status == 124 )); then
        error "$stage timed out after $timeout_duration: $source"
    else
        error "$stage failed with status $status: $source"
    fi
    [[ -z $SCAN_COMMAND_OUTPUT ]] || \
        operational_continuation stderr "$SCAN_COMMAND_OUTPUT"
    return 1
}

clean_scan_page() (
    local source=$1
    local scan_directory=$2
    local page=$3
    local page_count=$4
    local cleanup_mode=$5
    local timeout_command=$6
    local timeout_duration=$7
    local pdftocairo_command=$8
    local scan_clean_command=$9
    local rendered=$scan_directory/rendered/page-$page
    local cleaned=$scan_directory/cleaned/page-$page.png
    local command_output=$scan_directory/workers/page-$page.command-output
    local metrics_output=$scan_directory/workers/page-$page.metrics
    local child_pid=''
    local status started=$SECONDS

    # Invoked indirectly by the EXIT trap below.
    # shellcheck disable=SC2329
    finish_worker_metrics() {
        local worker_status=$?

        trap - EXIT
        if (( METRICS_ACTIVE )); then
            printf '%s\n' "$((SECONDS - started))" >"$metrics_output" || true
        fi
        rm -f -- "$command_output"
        exit "$worker_status"
    }

    # Invoked indirectly by the signal traps below.
    # shellcheck disable=SC2329
    stop_worker_child() {
        local signal_status=$1

        if [[ -n $child_pid ]]; then
            kill "$child_pid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
        fi
        rm -f -- "$command_output"
        exit "$signal_status"
    }

    run_page_command() {
        local stage=$1
        shift

        : >"$command_output" || return 1
        "$timeout_command" -- "$timeout_duration" "$@" \
            >"$command_output" 2>&1 &
        child_pid=$!
        wait "$child_pid"
        status=$?
        child_pid=''
        if (( status == 0 )); then
            return 0
        fi
        if (( status == 124 )); then
            error "$stage timed out after $timeout_duration: $source"
        else
            error "$stage failed with status $status: $source"
        fi
        if [[ -s $command_output ]]; then
            operational_continuation stderr "$(<"$command_output")"
        fi
        return 1
    }

    trap 'stop_worker_child 129' HUP
    trap 'stop_worker_child 130' INT
    trap 'stop_worker_child 143' TERM
    trap finish_worker_metrics EXIT

    verbose "rendering page $page of $page_count: $source"
    run_page_command 'scan page rendering' \
        "$pdftocairo_command" -png -singlefile -f "$page" -l "$page" \
        -rx "${SCAN_X_DPI[$page]}" -ry "${SCAN_Y_DPI[$page]}" \
        "$source" "$rendered" || exit 1
    if [[ ! -s $rendered.png ]]; then
        error "scan renderer produced no page image (page $page): $source"
        exit 1
    fi
    verbose "cleaning page $page of $page_count ($cleanup_mode): $source"
    run_page_command 'scan contrast cleanup' \
        "$scan_clean_command" --input "$rendered.png" --output "$cleaned" \
        --mode "$cleanup_mode" --strip-metadata \
        --timeout "$timeout_duration" || exit 1
    if [[ ! -s $cleaned ]]; then
        error "scan cleanup produced no page image (page $page): $source"
        exit 1
    fi
)

inspect_scan_pdf() {
    local source=$1
    local scan_directory=$2
    local timeout_command=$3
    local timeout_duration=$4
    local gs_command=$5
    local magick_command=$6
    local pdfinfo_command=$7
    local pdfimages_command=$8
    local pdftotext_command=$9
    local pdfdetach_command=${10}
    local pages encrypted form javascript compact page type
    local width height color components object generation x_dpi y_dpi
    local page_width page_height page_rotation swap minimum residual image_key
    local i
    local -a image_counts=()
    local -a smask_counts=()
    local -a image_keys=()
    local -a smask_keys=()
    local -a fields=()

    run_scan_command 'PDF inspection' "$source" "$timeout_command" \
        "$timeout_duration" "$pdfinfo_command" "$source" || return 1
    pages=$(printf '%s\n' "$SCAN_COMMAND_OUTPUT" | \
        awk -F: '$1 == "Pages" { sub(/^[[:space:]]+/, "", $2); print $2; exit }')
    encrypted=$(printf '%s\n' "$SCAN_COMMAND_OUTPUT" | \
        awk -F: '$1 == "Encrypted" { sub(/^[[:space:]]+/, "", $2); print $2; exit }')
    form=$(printf '%s\n' "$SCAN_COMMAND_OUTPUT" | \
        awk -F: '$1 == "Form" { sub(/^[[:space:]]+/, "", $2); print $2; exit }')
    javascript=$(printf '%s\n' "$SCAN_COMMAND_OUTPUT" | \
        awk -F: '$1 == "JavaScript" { sub(/^[[:space:]]+/, "", $2); print $2; exit }')
    if [[ ! $pages =~ ^[1-9][0-9]*$ ]]; then
        error "could not determine a positive page count for scan cleanup: $source"
        return 1
    fi
    if [[ $encrypted != no ]]; then
        error "scan cleanup requires an unencrypted PDF: $source"
        return 1
    fi
    if [[ $form != none ]]; then
        error "scan cleanup refuses PDFs containing forms: $source"
        return 1
    fi
    if [[ $javascript != no ]]; then
        error "scan cleanup refuses PDFs containing JavaScript: $source"
        return 1
    fi

    run_scan_command 'page geometry inspection' "$source" "$timeout_command" \
        "$timeout_duration" "$pdfinfo_command" -f 1 -l "$pages" -box \
        "$source" || return 1
    SCAN_PAGE_WIDTH=()
    SCAN_PAGE_HEIGHT=()
    SCAN_PAGE_ROTATION=()
    while read -r -a fields; do
        [[ ${fields[0]:-} == Page ]] || continue
        page=${fields[1]:-}
        [[ $page =~ ^[1-9][0-9]*$ ]] || continue
        case ${fields[2]:-} in
            size:)
                page_width=${fields[3]:-}
                page_height=${fields[5]:-}
                if [[ $page_width =~ ^[0-9]+([.][0-9]+)?$ &&
                    $page_height =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                    SCAN_PAGE_WIDTH[page]=$page_width
                    SCAN_PAGE_HEIGHT[page]=$page_height
                fi
                ;;
            rot:)
                page_rotation=${fields[3]:-}
                if [[ $page_rotation =~ ^(0|90|180|270)$ ]]; then
                    SCAN_PAGE_ROTATION[page]=$page_rotation
                fi
                ;;
        esac
    done <<<"$SCAN_COMMAND_OUTPUT"
    i=1
    while (( i <= pages )); do
        if [[ -z ${SCAN_PAGE_WIDTH[$i]:-} ||
            -z ${SCAN_PAGE_HEIGHT[$i]:-} ||
            -z ${SCAN_PAGE_ROTATION[$i]:-} ]]; then
            error "could not determine page geometry for scan cleanup (page $i): $source"
            return 1
        fi
        case ${SCAN_PAGE_ROTATION[$i]} in
            90|270)
                swap=${SCAN_PAGE_WIDTH[i]}
                SCAN_PAGE_WIDTH[i]=${SCAN_PAGE_HEIGHT[i]}
                SCAN_PAGE_HEIGHT[i]=$swap
                ;;
        esac
        ((i += 1))
    done

    run_scan_command 'text inspection' "$source" "$timeout_command" \
        "$timeout_duration" "$pdftotext_command" "$source" - || return 1
    compact=$(printf '%s' "$SCAN_COMMAND_OUTPUT" | LC_ALL=C tr -d '[:space:]')
    if [[ -n $compact ]]; then
        error "scan cleanup refuses PDFs containing searchable text: $source"
        return 1
    fi

    run_scan_command 'attachment inspection' "$source" "$timeout_command" \
        "$timeout_duration" "$pdfdetach_command" -list "$source" || return 1
    compact=$(printf '%s\n' "$SCAN_COMMAND_OUTPUT" | \
        sed -e '/^[[:space:]]*0 embedded files[[:space:]]*$/d' \
            -e '/^[[:space:]]*$/d')
    if [[ -n $compact ]]; then
        error "scan cleanup refuses PDFs containing embedded files: $source"
        return 1
    fi

    run_scan_command 'link inspection' "$source" "$timeout_command" \
        "$timeout_duration" "$pdfinfo_command" -url "$source" || return 1
    compact=$(printf '%s\n' "$SCAN_COMMAND_OUTPUT" | sed '1d' | \
        LC_ALL=C tr -d '[:space:]')
    if [[ -n $compact ]]; then
        error "scan cleanup refuses PDFs containing links: $source"
        return 1
    fi
    run_scan_command 'destination inspection' "$source" "$timeout_command" \
        "$timeout_duration" "$pdfinfo_command" -dests "$source" || return 1
    compact=$(printf '%s\n' "$SCAN_COMMAND_OUTPUT" | sed '1d' | \
        LC_ALL=C tr -d '[:space:]')
    if [[ -n $compact ]]; then
        error "scan cleanup refuses PDFs containing named destinations: $source"
        return 1
    fi

    run_scan_command 'image inspection' "$source" "$timeout_command" \
        "$timeout_duration" "$pdfimages_command" -list "$source" || return 1
    SCAN_X_DPI=()
    SCAN_Y_DPI=()
    SCAN_IMAGE_WIDTH=()
    SCAN_IMAGE_HEIGHT=()
    SCAN_IMAGE_COLOR=()
    while read -r -a fields; do
        page=${fields[0]:-}
        [[ $page =~ ^[1-9][0-9]*$ ]] || continue
        type=${fields[2]:-}
        width=${fields[3]:-}
        height=${fields[4]:-}
        color=${fields[5]:-}
        components=${fields[6]:-}
        object=${fields[10]:-}
        generation=${fields[11]:-}
        x_dpi=${fields[12]:-}
        y_dpi=${fields[13]:-}
        if [[ ! $width =~ ^[1-9][0-9]*$ ||
            ! $height =~ ^[1-9][0-9]*$ ||
            ! $object =~ ^[1-9][0-9]*$ || ! $generation =~ ^[0-9]+$ ||
            ! $x_dpi =~ ^[1-9][0-9]*$ ||
            ! $y_dpi =~ ^[1-9][0-9]*$ ]]; then
            error "scan cleanup requires exactly one ordinary image per page: $source"
            return 1
        fi
        image_key=$object:$generation:$width:$height:$x_dpi:$y_dpi
        case $type in
            image)
                image_counts[page]=$((${image_counts[page]:-0} + 1))
                image_keys[page]=$image_key
                SCAN_X_DPI[page]=$x_dpi
                SCAN_Y_DPI[page]=$y_dpi
                SCAN_IMAGE_WIDTH[page]=$width
                SCAN_IMAGE_HEIGHT[page]=$height
                SCAN_IMAGE_COLOR[page]=$color
                ;;
            smask)
                if [[ $color != gray || $components != 1 ]]; then
                    error "scan cleanup requires a grayscale, single-component soft mask: $source"
                    return 1
                fi
                smask_counts[page]=$((${smask_counts[page]:-0} + 1))
                smask_keys[page]=$image_key
                ;;
            *)
                error "scan cleanup requires exactly one ordinary image per page: $source"
                return 1
                ;;
        esac
    done <<<"$SCAN_COMMAND_OUTPUT"
    i=1
    while (( i <= pages )); do
        if (( ${image_counts[$i]:-0} != 1 )); then
            error "scan cleanup requires exactly one image on every page (page $i): $source"
            return 1
        fi
        if (( ${smask_counts[$i]:-0} > 1 )); then
            error "scan cleanup allows at most one associated soft mask per page (page $i): $source"
            return 1
        fi
        if (( ${smask_counts[$i]:-0} == 1 )) &&
            [[ ${smask_keys[$i]} != "${image_keys[$i]}" ]]; then
            error "scan cleanup soft mask does not match its page image (page $i): $source"
            return 1
        fi
        ((i += 1))
    done

    mkdir "$scan_directory/residual" || return 1
    run_scan_command 'non-image content inspection' "$source" "$timeout_command" \
        "$timeout_duration" "$gs_command" -q -dBATCH -dNOPAUSE -dSAFER \
        -dFILTERIMAGE -sDEVICE=pnggray -r150 \
        "-sOutputFile=$scan_directory/residual/page-%04d.png" -f "$source" || \
        return 1
    i=1
    while (( i <= pages )); do
        printf -v residual '%s/residual/page-%04d.png' "$scan_directory" "$i"
        if [[ ! -s $residual ]]; then
            error "could not inspect non-image page content (page $i): $source"
            return 1
        fi
        run_scan_command 'non-image content analysis' "$source" \
            "$timeout_command" "$timeout_duration" "$magick_command" \
            "$residual" -format '%[fx:minima]' info: || return 1
        minimum=$SCAN_COMMAND_OUTPUT
        if ! awk -v value="$minimum" 'BEGIN { exit !(value >= 0.99999) }'; then
            error "scan cleanup refuses PDFs containing visible text or vector content (page $i): $source"
            return 1
        fi
        ((i += 1))
    done
    SCAN_PAGE_COUNT=$pages
}

clean_scan_pdf() {
    local source=$1
    local cleaned_pdf=$2
    local scan_directory=$3
    local cleanup_mode=$4
    local timeout_command=$5
    local timeout_duration=$6
    local gs_command=$7
    local magick_command=$8
    local pdfinfo_command=$9
    local pdfimages_command=${10}
    local pdftotext_command=${11}
    local pdfdetach_command=${12}
    local pdftocairo_command=${13}
    local scan_clean_command=${14}
    local jobs=${15:-auto}
    local page rendered cleaned dimensions pixel_width pixel_height
    local output_x_dpi output_y_dpi
    local worker_pid worker_log worker_status worker_page worker_metrics
    local worker_duration
    local stage_start
    local next_page=1 failed=0
    local -a assembly_args=()
    local -a worker_pids=()
    local -a worker_logs=()
    local -a worker_pages=()

    verbose "inspecting PDF for safe image-only cleanup: $source"
    if (( METRICS_ACTIVE )); then
        METRIC_FAILURE_STAGE=inspection
        stage_start=$SECONDS
    fi
    if ! inspect_scan_pdf "$source" "$scan_directory" "$timeout_command" \
        "$timeout_duration" "$gs_command" "$magick_command" \
        "$pdfinfo_command" "$pdfimages_command" "$pdftotext_command" \
        "$pdfdetach_command"; then
        if (( METRICS_ACTIVE )); then
            METRIC_INSPECTION_SECONDS=$((SECONDS - stage_start))
        fi
        return 1
    fi
    if (( METRICS_ACTIVE )); then
        METRIC_INSPECTION_SECONDS=$((SECONDS - stage_start))
        collect_scan_shape_metrics
    fi
    verbose "scan inspection accepted $SCAN_PAGE_COUNT page(s): $source"
    if [[ $jobs == auto ]]; then
        jobs=$SCAN_PAGE_COUNT
        if (( jobs > AUTOMATIC_SCAN_JOB_CAP )); then
            jobs=$AUTOMATIC_SCAN_JOB_CAP
        fi
        verbose "scan cleanup workers: $jobs (automatic for $SCAN_PAGE_COUNT page(s))"
    else
        verbose "scan cleanup workers: $jobs (explicit for $SCAN_PAGE_COUNT page(s))"
    fi
    if (( METRICS_ACTIVE )); then
        METRIC_EFFECTIVE_WORKERS=$jobs
        METRIC_MAX_ACTIVE_WORKERS=0
        METRIC_FAILURE_STAGE='page-cleanup'
        stage_start=$SECONDS
    fi
    mkdir "$scan_directory/rendered" "$scan_directory/cleaned" \
        "$scan_directory/workers" || return 1
    while (( next_page <= SCAN_PAGE_COUNT || ${#worker_pids[@]} )); do
        while (( ! failed && next_page <= SCAN_PAGE_COUNT && \
            ${#worker_pids[@]} < jobs )); do
            worker_log=$scan_directory/workers/page-$next_page.log
            clean_scan_page "$source" "$scan_directory" "$next_page" \
                "$SCAN_PAGE_COUNT" "$cleanup_mode" "$timeout_command" \
                "$timeout_duration" "$pdftocairo_command" \
                "$scan_clean_command" >"$worker_log" 2>&1 &
            worker_pid=$!
            ACTIVE_SCAN_WORKERS[${#ACTIVE_SCAN_WORKERS[@]}]=$worker_pid
            worker_pids[${#worker_pids[@]}]=$worker_pid
            worker_logs[${#worker_logs[@]}]=$worker_log
            worker_pages[${#worker_pages[@]}]=$next_page
            if (( METRICS_ACTIVE && \
                ${#worker_pids[@]} > METRIC_MAX_ACTIVE_WORKERS )); then
                METRIC_MAX_ACTIVE_WORKERS=${#worker_pids[@]}
            fi
            ((next_page += 1))
        done
        (( ${#worker_pids[@]} )) || break
        worker_pid=${worker_pids[0]}
        worker_log=${worker_logs[0]}
        worker_page=${worker_pages[0]}
        wait "$worker_pid"
        worker_status=$?
        remove_active_scan_worker "$worker_pid"
        if (( METRICS_ACTIVE )); then
            worker_metrics=$scan_directory/workers/page-$worker_page.metrics
            if [[ -s $worker_metrics ]]; then
                IFS= read -r worker_duration <"$worker_metrics" || \
                    worker_duration='-'
                METRIC_PAGE_TIMES[worker_page]=$worker_duration
            else
                METRIC_PAGE_TIMES[worker_page]='-'
            fi
        fi
        if [[ -s $worker_log ]]; then
            OPERATIONAL_LAST_STREAM=stderr
            while IFS= read -r rendered; do
                raw_output_line stderr "$rendered"
            done <"$worker_log"
        fi
        (( worker_status == 0 )) || failed=1
        worker_pids=( "${worker_pids[@]:1}" )
        worker_logs=( "${worker_logs[@]:1}" )
        worker_pages=( "${worker_pages[@]:1}" )
    done
    if (( METRICS_ACTIVE )); then
        METRIC_CLEANUP_SECONDS=$((SECONDS - stage_start))
    fi
    (( failed == 0 )) || return 1

    if (( METRICS_ACTIVE )); then
        METRIC_FAILURE_STAGE=assembly
        stage_start=$SECONDS
    fi
    page=1
    while (( page <= SCAN_PAGE_COUNT )); do
        cleaned=$scan_directory/cleaned/page-$page.png
        run_scan_command 'cleaned page geometry inspection' "$source" \
            "$timeout_command" "$timeout_duration" "$magick_command" \
            "$cleaned" -format '%w %h' info: || return 1
        dimensions=$SCAN_COMMAND_OUTPUT
        read -r pixel_width pixel_height <<<"$dimensions"
        if [[ ! $pixel_width =~ ^[1-9][0-9]*$ ||
            ! $pixel_height =~ ^[1-9][0-9]*$ ]]; then
            error "could not determine cleaned page dimensions (page $page): $source"
            return 1
        fi
        output_x_dpi=$(awk -v pixels="$pixel_width" \
            -v points="${SCAN_PAGE_WIDTH[$page]}" \
            'BEGIN { printf "%.8f", pixels * 72 / points }')
        output_y_dpi=$(awk -v pixels="$pixel_height" \
            -v points="${SCAN_PAGE_HEIGHT[$page]}" \
            'BEGIN { printf "%.8f", pixels * 72 / points }')
        assembly_args+=(
            '('
            "$cleaned"
            -set units PixelsPerInch
            -set density "${output_x_dpi}x${output_y_dpi}"
            ')'
        )
        ((page += 1))
    done
    verbose "assembling $SCAN_PAGE_COUNT cleaned page(s): $source"
    run_scan_command 'cleaned PDF assembly' "$source" "$timeout_command" \
        "$timeout_duration" "$magick_command" "${assembly_args[@]}" \
        -compress Zip "$cleaned_pdf" || return 1
    if [[ ! -f $cleaned_pdf || -L $cleaned_pdf || ! -s $cleaned_pdf ]]; then
        error "scan cleanup produced no valid nonempty PDF: $source"
        return 1
    fi
    if (( METRICS_ACTIVE )); then
        METRIC_ASSEMBLY_SECONDS=$((SECONDS - stage_start))
    fi
}

clean_image_to_pdf() {
    local source=$1
    local cleaned_pdf=$2
    local scan_directory=$3
    local cleanup_mode=$4
    local timeout_command=$5
    local timeout_duration=$6
    local magick_command=$7
    local scan_clean_command=$8
    local cleaned_image=$scan_directory/cleaned.png
    local source_x_dpi source_y_dpi source_units
    local output_x_dpi=$DEFAULT_IMAGE_INPUT_DPI
    local output_y_dpi=$DEFAULT_IMAGE_INPUT_DPI

    verbose "inspecting image density: $source"
    run_scan_command 'image density inspection' "$source" "$timeout_command" \
        "$timeout_duration" "$magick_command" identify -quiet \
        -format '%x|%y|%[units]' "$source" || return 1
    IFS='|' read -r source_x_dpi source_y_dpi source_units \
        <<<"$SCAN_COMMAND_OUTPUT"
    case $source_units in
        PixelsPerInch)
            output_x_dpi=$source_x_dpi
            output_y_dpi=$source_y_dpi
            ;;
        PixelsPerCentimeter)
            output_x_dpi=$(awk -v value="$source_x_dpi" \
                'BEGIN { printf "%.8f", value * 2.54 }')
            output_y_dpi=$(awk -v value="$source_y_dpi" \
                'BEGIN { printf "%.8f", value * 2.54 }')
            ;;
    esac
    if ! awk -v x="$output_x_dpi" -v y="$output_y_dpi" \
        -v minimum="$MINIMUM_CREDIBLE_IMAGE_DPI" \
        'BEGIN { exit !(x >= minimum && y >= minimum) }'; then
        output_x_dpi=$DEFAULT_IMAGE_INPUT_DPI
        output_y_dpi=$DEFAULT_IMAGE_INPUT_DPI
    fi
    verbose "PDF image density: ${output_x_dpi}x${output_y_dpi} DPI"

    verbose "cleaning raster image ($cleanup_mode): $source"
    run_scan_command 'image scan cleanup' "$source" "$timeout_command" \
        "$timeout_duration" "$scan_clean_command" \
        --input "$source" --output "$cleaned_image" \
        --mode "$cleanup_mode" --strip-metadata \
        --timeout "$timeout_duration" || return 1
    if [[ ! -f $cleaned_image || -L $cleaned_image || ! -s $cleaned_image ]]; then
        error "scan cleanup produced no valid image: $source"
        return 1
    fi
    verbose "assembling cleaned image as PDF: $source"
    run_scan_command 'cleaned image PDF assembly' "$source" "$timeout_command" \
        "$timeout_duration" "$magick_command" -units PixelsPerInch \
        -density "${output_x_dpi}x${output_y_dpi}" "$cleaned_image" \
        -compress Zip "$cleaned_pdf" || return 1
    if [[ ! -f $cleaned_pdf || -L $cleaned_pdf || ! -s $cleaned_pdf ]]; then
        error "scan cleanup produced no valid nonempty PDF: $source"
        return 1
    fi
}

convert_pdf() {
    local source=$1
    local candidate=$2
    local timeout_command=$3
    local gs_command=$4
    local timeout_duration=$5
    local grayscale=$6
    local quality=$7
    local max_dpi=${8:-}
    local jpeg_recompress=${9:-}
    local output status
    local distiller_params=''
    local qfactor
    local pass_through_jpeg=true
    local -a gs_args

    if [[ ! -f $candidate || -L $candidate || -s $candidate ]]; then
        error "candidate must be an existing empty regular file: $candidate"
        return 1
    fi

    gs_args=(
        -dBATCH
        -dNOPAUSE
        -dSAFER
        -sDEVICE=pdfwrite
    )
    if (( grayscale )); then
        gs_args+=(
            -sColorConversionStrategy=Gray
            -dProcessColorModel=/DeviceGray
        )
    fi
    case $quality in
        preserve)
            gs_args+=(
                -dAutoFilterColorImages=false
                -dColorImageFilter=/FlateEncode
                -dAutoFilterGrayImages=false
                -dGrayImageFilter=/FlateEncode
            )
            ;;
        balanced)
            gs_args+=(
                -dAutoFilterColorImages=false
                -dColorImageFilter=/DCTEncode
                -dAutoFilterGrayImages=false
                -dGrayImageFilter=/DCTEncode
                -dPassThroughJPEGImages=true
                -dPassThroughJPXImages=true
                -dDownsampleColorImages=true
                -dColorImageDownsampleType=/Bicubic
                -dColorImageDownsampleThreshold=1.0
                -dColorImageResolution=300
                -dDownsampleGrayImages=true
                -dGrayImageDownsampleType=/Bicubic
                -dGrayImageDownsampleThreshold=1.0
                -dGrayImageResolution=300
                -dDownsampleMonoImages=true
                -dMonoImageDownsampleType=/Bicubic
                -dMonoImageDownsampleThreshold=1.0
                -dMonoImageResolution=600
            )
            distiller_params='<< /ColorImageDict << /QFactor 0.15 /Blend 1 /ColorTransform 1 /HSamples [1 1 1 1] /VSamples [1 1 1 1] >> /GrayImageDict << /QFactor 0.15 /Blend 1 >> >> setdistillerparams'
            ;;
        small)
            gs_args+=(
                -dAutoFilterColorImages=false
                -dColorImageFilter=/DCTEncode
                -dAutoFilterGrayImages=false
                -dGrayImageFilter=/DCTEncode
                -dPassThroughJPEGImages=true
                -dPassThroughJPXImages=true
                -dDownsampleColorImages=true
                -dColorImageDownsampleType=/Bicubic
                -dColorImageDownsampleThreshold=1.0
                -dColorImageResolution=250
                -dDownsampleGrayImages=true
                -dGrayImageDownsampleType=/Bicubic
                -dGrayImageDownsampleThreshold=1.0
                -dGrayImageResolution=250
                -dDownsampleMonoImages=true
                -dMonoImageDownsampleType=/Bicubic
                -dMonoImageDownsampleThreshold=1.0
                -dMonoImageResolution=600
            )
            distiller_params='<< /ColorImageDict << /QFactor 0.4 /Blend 1 /ColorTransform 1 /HSamples [1 1 1 1] /VSamples [1 1 1 1] >> /GrayImageDict << /QFactor 0.4 /Blend 1 >> >> setdistillerparams'
            ;;
        detailed)
            qfactor=${jpeg_recompress:-0.15}
            [[ -z $jpeg_recompress ]] || pass_through_jpeg=false
            gs_args+=(
                -dAutoFilterColorImages=false
                -dColorImageFilter=/DCTEncode
                -dAutoFilterGrayImages=false
                -dGrayImageFilter=/DCTEncode
                "-dPassThroughJPEGImages=$pass_through_jpeg"
                -dPassThroughJPXImages=true
            )
            if [[ -n $max_dpi ]]; then
                gs_args+=(
                    -dDownsampleColorImages=true
                    -dColorImageDownsampleType=/Bicubic
                    -dColorImageDownsampleThreshold=1.0
                    "-dColorImageResolution=$max_dpi"
                    -dDownsampleGrayImages=true
                    -dGrayImageDownsampleType=/Bicubic
                    -dGrayImageDownsampleThreshold=1.0
                    "-dGrayImageResolution=$max_dpi"
                )
            else
                gs_args+=(
                    -dDownsampleColorImages=false
                    -dDownsampleGrayImages=false
                )
            fi
            gs_args+=(
                -dDownsampleMonoImages=true
                -dMonoImageDownsampleType=/Bicubic
                -dMonoImageDownsampleThreshold=1.0
                -dMonoImageResolution=600
            )
            distiller_params="<< /ColorImageDict << /QFactor $qfactor /Blend 1 /ColorTransform 1 /HSamples [1 1 1 1] /VSamples [1 1 1 1] >> /GrayImageDict << /QFactor $qfactor /Blend 1 >> >> setdistillerparams"
            ;;
    esac
    gs_args+=("-sOutputFile=$candidate")
    if [[ -n $distiller_params ]]; then
        gs_args+=(-c "$distiller_params")
    fi
    gs_args+=(-f "$source")

    output=$("$timeout_command" -- "$timeout_duration" \
        "$gs_command" "${gs_args[@]}" 2>&1)
    status=$?

    if (( status != 0 )); then
        if (( status == 124 )); then
            error "conversion timed out after $timeout_duration: $source"
        else
            error "Ghostscript failed with status $status: $source"
        fi
        if [[ -n $output ]]; then
            operational_continuation stderr "$output"
        fi
        remove_candidate "$candidate"
        return 1
    fi

    if [[ ! -f $candidate || -L $candidate || ! -s $candidate ]]; then
        error "Ghostscript produced no valid nonempty PDF candidate: $source"
        if [[ -n $output ]]; then
            operational_continuation stderr "$output"
        fi
        remove_candidate "$candidate"
        return 1
    fi

    return 0
}

is_pdf_name() {
    case $1 in
        *.[pP][dD][fF]) return 0 ;;
        *) return 1 ;;
    esac
}

is_raster_image_name() {
    local name=${1##*/}
    local extension

    [[ $name == *.* ]] || return 1
    extension=$(printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]')
    case $extension in
        avif|bmp|gif|heic|heif|j2c|j2k|jp2|jpe|jpeg|jpg|jxl|pam|pbm|pgm|png|pnm|ppm|tif|tiff|webp)
            return 0
            ;;
        *) return 1 ;;
    esac
}

image_relative_to_pdf() {
    local relative=$1
    local directory=${relative%/*}
    local name=${relative##*/}

    [[ $directory != "$relative" ]] || directory=''
    name=${name%.*}.pdf
    if [[ -n $directory ]]; then
        printf '%s/%s\n' "$directory" "$name"
    else
        printf '%s\n' "$name"
    fi
}

absolute_path() {
    local path=$1
    local segment result=''
    local -a components=()

    [[ $path == /* ]] || path=$PWD/$path
    while :; do
        if [[ $path == */* ]]; then
            segment=${path%%/*}
            path=${path#*/}
        else
            segment=$path
            path=''
        fi
        case $segment in
            ''|.) ;;
            ..)
                if (( ${#components[@]} )); then
                    unset 'components[${#components[@]}-1]'
                fi
                ;;
            *) components[${#components[@]}]=$segment ;;
        esac
        [[ -n $path ]] || break
    done

    for segment in "${components[@]}"; do
        result=$result/$segment
    done
    printf '%s\n' "${result:-/}"
}

append_source() {
    local source=$1
    local relative=$2
    local canonical existing source_type
    local i

    if [[ -L $source ]]; then
        warn "skipping symlink: $source"
        return 0
    fi
    if [[ ! -f $source ]]; then
        warn "skipping non-regular file: $source"
        return 0
    fi
    if is_pdf_name "$source"; then
        source_type=pdf
    elif [[ -n $clean_scan ]] && is_raster_image_name "$source"; then
        if [[ $mode == replace ]]; then
            error "--replace cannot be used with raster-image input: $source"
            return 1
        fi
        source_type=image
    else
        if [[ -n $clean_scan ]]; then
            warn "skipping non-PDF/non-raster file: $source"
        else
            warn "skipping non-PDF file: $source"
        fi
        return 0
    fi

    canonical=$(realpath -- "$source") || {
        error "cannot resolve input: $source"
        return 1
    }

    i=0
    while (( i < ${#source_keys[@]} )); do
        existing=${source_keys[$i]}
        if [[ $existing == "$canonical" ]]; then
            return 0
        fi
        ((i += 1))
    done

    sources[${#sources[@]}]=$source
    source_keys[${#source_keys[@]}]=$canonical
    relatives[${#relatives[@]}]=$relative
    source_types[${#source_types[@]}]=$source_type
}

discover_directory() {
    local directory=$1
    local found=0
    local path relative
    local -a find_args

    find_args=(find -P "$directory")
    if (( recursive )); then
        find_args+=( -mindepth 1 )
    else
        find_args+=( -mindepth 1 -maxdepth 1 )
    fi
    find_args+=( \( -type l -o -type f \) -print0 )

    while IFS= read -r -d '' path; do
        found=1
        relative=${path#"$directory"/}
        if [[ $mode == output ]]; then
            local source_key
            source_key=$(realpath -- "$path") || {
                error "cannot resolve input: $path"
                return 1
            }
            case $source_key in
                "$output_root_key"|"$output_root_key"/*)
                    warn "skipping output-directory content: $path"
                    continue
                    ;;
            esac
        fi
        append_source "$path" "$relative" || return 1
    done < <("${find_args[@]}")

    if (( ! found )); then
        warn "no files found in directory: $directory"
    fi
}

plan_actions() {
    local source relative output_relative destination destination_key
    local existing_source
    local i j
    local failures=0

    i=0
    while (( i < ${#sources[@]} )); do
        source=${sources[$i]}
        relative=${relatives[$i]}
        output_relative=$relative
        if [[ ${source_types[$i]} == image ]]; then
            output_relative=$(image_relative_to_pdf "$relative")
        fi
        if (( dry_run )) && [[ -n $clean_scan ]]; then
            operational_message stdout \
                "would clean scan ($clean_scan): $source"
        fi

        if [[ $mode == output ]]; then
            destination=$output_dir/$output_relative
            destination_key=$(absolute_path "$destination") || {
                error "cannot resolve destination: $destination"
                failures=1
                ((i += 1))
                continue
            }

            if [[ -e $destination || -L $destination ]]; then
                error "output destination already exists: $destination"
                failures=1
            fi

            j=0
            while (( j < ${#destination_keys[@]} )); do
                if [[ ${destination_keys[$j]} == "$destination_key" ]]; then
                    existing_source=${destination_sources[$j]}
                    error "destination collision: $source and $existing_source map to $destination"
                    failures=1
                    break
                fi
                ((j += 1))
            done
            destination_keys[${#destination_keys[@]}]=$destination_key
            destination_sources[${#destination_sources[@]}]=$source
            destinations[${#destinations[@]}]=$destination
            if (( dry_run )); then
                operational_message stdout \
                    "would convert: $source -> $destination"
            fi
        elif [[ $mode == file ]]; then
            destinations[${#destinations[@]}]=$output_file
            if (( dry_run )); then
                operational_message stdout \
                    "would convert: $source -> $output_file"
            fi
        else
            destinations[${#destinations[@]}]=$source
            if (( dry_run )); then
                operational_message stdout \
                    "would replace if smaller: $source"
            fi
        fi
        ((i += 1))
    done

    (( failures == 0 ))
}

clear_active_files() {
    stop_active_scan_workers
    remove_candidate "${ACTIVE_CANDIDATE:-}"
    remove_candidate "${ACTIVE_METADATA_REFERENCE:-}"
    remove_scan_directory "${ACTIVE_SCAN_DIRECTORY:-}"
    ACTIVE_CANDIDATE=''
    ACTIVE_METADATA_REFERENCE=''
    ACTIVE_SCAN_DIRECTORY=''
    release_log_lock
    release_metrics_lock
}

process_source_core() {
    local source=$1
    local relative=$2
    local destination=$3
    local source_type=${4:-pdf}
    local candidate='' candidate_dir source_before source_after
    local source_content_before source_fingerprint
    local timestamp_reference=''
    local scan_directory='' conversion_source=$source
    local original_size candidate_size metrics_stage_start

    PROCESS_OUTCOME=''
    PROCESS_ARTIFACT=''
    verbose "destination: $destination"

    if [[ $mode == output ]]; then
        ensure_output_parent "$relative" || return 1
        candidate_dir=${destination%/*}
        [[ $candidate_dir != "$destination" ]] || candidate_dir=.
    elif [[ $mode == file ]]; then
        candidate_dir=${destination%/*}
        [[ $candidate_dir != "$destination" ]] || candidate_dir=.
        candidate_dir=$(realpath -- "$candidate_dir") || {
            error "could not resolve output parent directory: $candidate_dir"
            return 1
        }
    else
        candidate_dir=${source%/*}
        [[ $candidate_dir != "$source" ]] || candidate_dir=.
    fi

    candidate=$(mktemp "$candidate_dir/.pdf-slim.XXXXXX") || {
        error "could not create candidate beside destination: $destination"
        return 1
    }
    ACTIVE_CANDIDATE=$candidate

    if [[ $metadata_mode == standard || $metadata_mode == all ]]; then
        timestamp_reference=$(mktemp "${TMPDIR:-/tmp}/pdf-slim-metadata.XXXXXX") || {
            error "could not preserve source timestamps: $source"
            clear_active_files
            return 1
        }
        ACTIVE_METADATA_REFERENCE=$timestamp_reference
        touch -r "$source" "$timestamp_reference" || {
            error "could not capture source timestamps: $source"
            clear_active_files
            return 1
        }
    fi

    prepare_candidate_metadata "$source" "$candidate" "$metadata_mode" || {
        error "could not prepare requested metadata: $source"
        clear_active_files
        return 1
    }
    source_fingerprint=$(file_fingerprint "$source") || {
        error "could not fingerprint source before conversion: $source"
        clear_active_files
        return 1
    }
    source_before=$(file_identity "$source") || {
        error "could not inspect source before conversion: $source"
        clear_active_files
        return 1
    }
    source_content_before=${source_before%:*}
    if [[ -n ${clean_scan:-} ]]; then
        scan_directory=$(mktemp -d "${TMPDIR:-/tmp}/pdf-slim-scan.XXXXXX") || {
            error "could not create scan-cleanup temporary directory: $source"
            clear_active_files
            return 1
        }
        ACTIVE_SCAN_DIRECTORY=$scan_directory
        scan_directory=$(realpath -- "$scan_directory") || {
            error "could not resolve scan-cleanup temporary directory: $source"
            clear_active_files
            return 1
        }
        ACTIVE_SCAN_DIRECTORY=$scan_directory
        conversion_source=$scan_directory/cleaned.pdf
        if [[ $source_type == image ]]; then
            clean_image_to_pdf "$source" "$conversion_source" \
                "$scan_directory" "$clean_scan" "$timeout_command" \
                "$timeout_duration" "$magick_command" \
                "$scan_clean_command"
        else
            clean_scan_pdf "$source" "$conversion_source" "$scan_directory" \
                "$clean_scan" "$timeout_command" "$timeout_duration" \
                "$gs_command" "$magick_command" "$pdfinfo_command" \
                "$pdfimages_command" "$pdftotext_command" \
                "$pdfdetach_command" "$pdftocairo_command" \
                "$scan_clean_command" "$jobs"
        fi || {
            clear_active_files
            return 1
        }
    fi
    verbose "optimizing PDF with Ghostscript: $source"
    if (( METRICS_ACTIVE )); then
        METRIC_FAILURE_STAGE=ghostscript
        metrics_stage_start=$SECONDS
    fi
    if ! convert_pdf "$conversion_source" "$candidate" "$timeout_command" \
        "$gs_command" "$timeout_duration" "$grayscale" "$quality" \
        "$max_dpi" "$jpeg_recompress"; then
        if (( METRICS_ACTIVE )); then
            METRIC_GHOSTSCRIPT_SECONDS=$((SECONDS - metrics_stage_start))
        fi
        clear_active_files
        return 1
    fi
    if (( METRICS_ACTIVE )); then
        METRIC_GHOSTSCRIPT_SECONDS=$((SECONDS - metrics_stage_start))
        METRIC_OUTPUT_BYTES=$(file_size "$candidate" 2>/dev/null || printf '%s' '-')
        METRIC_FAILURE_STAGE=postprocessing
    fi
    verbose "converted PDF validation passed: $source"
    remove_scan_directory "$scan_directory" || {
        clear_active_files
        return 1
    }
    ACTIVE_SCAN_DIRECTORY=''
    if ! verify_source_unchanged "$source" "$source_before" \
        "$source_content_before" "$source_fingerprint" 'during conversion'; then
        clear_active_files
        return 1
    fi
    source_before=$SOURCE_CHECK_IDENTITY
    finalize_candidate_metadata "$source" "$candidate" "$metadata_mode" \
        "$timestamp_reference" || {
        error "could not preserve requested metadata: $source"
        clear_active_files
        return 1
    }
    verbose "metadata preservation complete ($metadata_mode): $source"

    if [[ $mode == replace ]]; then
        original_size=$(file_size "$source") || {
            error "could not determine original size: $source"
            clear_active_files
            return 1
        }
        candidate_size=$(file_size "$candidate") || {
            error "could not determine converted size: $source"
            clear_active_files
            return 1
        }
        verbose "size comparison: source $original_size bytes; candidate $candidate_size bytes"
        if (( candidate_size >= original_size )); then
            operational_message stdout \
                "kept original (converted file was not smaller): $source"
            PROCESS_OUTCOME='kept-not-smaller'
            clear_active_files
            return 0
        fi
    fi

    if (( METRICS_ACTIVE )); then
        METRIC_FAILURE_STAGE=publication
    fi
    if [[ $mode != replace && ( -e $destination || -L $destination ) ]]; then
        error "output destination appeared during conversion: $destination"
        clear_active_files
        return 1
    fi
    if [[ $mode == replace ]]; then
        if ! verify_source_unchanged "$source" "$source_before" \
            "$source_content_before" "$source_fingerprint" \
            'before replacement'; then
            clear_active_files
            return 1
        fi
        source_after=$SOURCE_CHECK_IDENTITY
        if (( SOURCE_CHECK_METADATA_CHANGED )); then
            finalize_candidate_metadata "$source" "$candidate" \
                "$metadata_mode" "$timestamp_reference" || {
                error "could not refresh requested metadata: $source"
                clear_active_files
                return 1
            }
            verbose "metadata refreshed before replacement ($metadata_mode): $source"
        fi
        source_before=$source_after
    fi
    if [[ $mode == replace ]]; then
        verbose "publishing replacement atomically: $source"
        mv -- "$candidate" "$destination" || {
            error "could not publish converted PDF: $destination"
            clear_active_files
            return 1
        }
    else
        verbose "publishing output atomically: $destination"
        mv -n -- "$candidate" "$destination" || {
            error "could not publish converted PDF: $destination"
            clear_active_files
            return 1
        }
        if [[ -e $candidate || -L $candidate ]]; then
            error "output destination appeared during publication: $destination"
            clear_active_files
            return 1
        fi
        if [[ ! -f $destination || -L $destination || ! -s $destination ]]; then
            error "published output is not a valid nonempty regular file: $destination"
            clear_active_files
            return 1
        fi
    fi
    ACTIVE_CANDIDATE=''
    remove_candidate "$timestamp_reference"
    ACTIVE_METADATA_REFERENCE=''
    if [[ $mode == replace ]]; then
        operational_message stdout "replaced: $source"
        PROCESS_OUTCOME='replaced'
    else
        operational_message stdout "created: $destination"
    fi
}

process_source() {
    local source=$1
    local source_type=${4:-pdf}
    local status

    if [[ $source_type != pdf || -z ${clean_scan:-} ]]; then
        process_source_core "$@"
        return
    fi
    reset_performance_metrics
    METRIC_SOURCE_BYTES=$(file_size "$source" 2>/dev/null || printf '%s' '-')
    process_source_core "$@"
    status=$?
    finish_performance_metrics "$status"
    return "$status"
}

cleanup_active_candidate() {
    local status=$?
    clear_active_files
    if (( METRICS_ACTIVE )); then
        if (( status >= 128 )); then
            METRIC_FAILURE_STAGE=interruption
        fi
        finish_performance_metrics "$status"
    fi
    finish_operational_output
    trap - EXIT
    exit "$status"
}

main() {
    local output_dir=''
    local output_file=''
    local mode=''
    local timeout_duration='1h'
    local jobs=auto
    local quality='preserve'
    local max_dpi=''
    local jpeg_recompress=''
    local clean_scan=''
    local metadata_mode='standard'
    local dry_run=0
    local grayscale=0
    local reprocess=0
    local recursive=0
    local arg directory relative output_parent input_value match
    local parse_failed=0
    local discovery_failed=0
    local quality_explicit=0
    local detailed_quality=0
    local clean_scan_mode_explicit=0
    local jobs_explicit=0
    local metadata_mode_explicit=0
    local pattern_found=0
    local -a inputs=()
    local -a sources=()
    local -a source_keys=()
    local -a relatives=()
    local -a source_types=()
    local -a destination_keys=()
    local -a destination_sources=()
    local -a destinations=()
    local output_root_key=''
    local log_file lookup_log old_log_file script_path state_directory
    local processing_policy
    local timeout_command gs_command magick_command pdfinfo_command
    local pdfimages_command pdftotext_command pdfdetach_command
    local pdftocairo_command scan_clean_command
    local failures=0 i needs_pdf_scan_tools=0
    ACTIVE_CANDIDATE=''
    ACTIVE_METADATA_REFERENCE=''
    ACTIVE_SCAN_DIRECTORY=''
    ACTIVE_SCAN_WORKERS=()
    ACTIVE_LOG_LOCK=''
    VERBOSE=0

    if (( $# == 0 )); then
        error 'an output mode and at least one input are required'
        printf '\n' >&2
        usage_hint
        return 2
    fi

    while (( $# )); do
        arg=$1
        shift
        case $arg in
            -i|--input)
                if (( $# == 0 )); then
                    error "$arg requires a path argument"
                    parse_failed=1
                    break
                fi
                input_value=$1
                shift
                if [[ -e $input_value || -L $input_value ||
                    ( $input_value != *'*'* && $input_value != *'?'* &&
                    $input_value != *'['* ) ]]; then
                    inputs[${#inputs[@]}]=$input_value
                    continue
                fi
                pattern_found=0
                while IFS= read -r -d '' match; do
                    inputs[${#inputs[@]}]=$match
                    pattern_found=1
                done < <(expand_input_pattern "$input_value")
                if (( ! pattern_found )); then
                    error "input pattern matched no paths: $input_value"
                    parse_failed=1
                fi
                ;;
            -o|--output)
                if (( $# == 0 )); then
                    error "$arg requires a file argument"
                    parse_failed=1
                    break
                fi
                output_file=$1
                shift
                if [[ -n $mode ]]; then
                    error 'output modes are mutually exclusive'
                    parse_failed=1
                else
                    mode='file'
                fi
                ;;
            --output-dir)
                if (( $# == 0 )); then
                    error '--output-dir requires a directory argument'
                    parse_failed=1
                    break
                fi
                output_dir=$1
                shift
                if [[ -n $mode ]]; then
                    error 'output modes are mutually exclusive'
                    parse_failed=1
                else
                    mode=output
                fi
                ;;
            --replace)
                if [[ -n $mode ]]; then
                    error 'output modes are mutually exclusive'
                    parse_failed=1
                else
                    mode=replace
                fi
                ;;
            --recursive) recursive=1 ;;
            --reprocess) reprocess=1 ;;
            --timeout)
                if (( $# == 0 )); then
                    error '--timeout requires a duration argument'
                    parse_failed=1
                    break
                fi
                timeout_duration=$1
                shift
                ;;
            --jobs)
                if (( $# == 0 )); then
                    error '--jobs requires an integer argument'
                    parse_failed=1
                    break
                fi
                jobs=$1
                jobs_explicit=1
                shift
                ;;
            --dry-run) dry_run=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            --quality)
                if (( $# == 0 )); then
                    error '--quality requires a mode argument'
                    parse_failed=1
                    break
                fi
                quality=$1
                shift
                quality_explicit=1
                ;;
            --max-dpi)
                if (( $# == 0 )); then
                    error '--max-dpi requires a DPI argument'
                    parse_failed=1
                    break
                fi
                max_dpi=$1
                shift
                detailed_quality=1
                ;;
            --jpeg-recompress)
                if (( $# == 0 )); then
                    error '--jpeg-recompress requires a QFactor argument'
                    parse_failed=1
                    break
                fi
                jpeg_recompress=$1
                shift
                detailed_quality=1
                ;;
            --grayscale) grayscale=1 ;;
            --clean-scan)
                clean_scan=standard
                if (( $# )) && [[ $1 != -* ]]; then
                    clean_scan=$1
                    clean_scan_mode_explicit=1
                    shift
                fi
                ;;
            --preserve-metadata)
                if (( $# == 0 )); then
                    error '--preserve-metadata requires a mode argument'
                    parse_failed=1
                    break
                fi
                metadata_mode=$1
                metadata_mode_explicit=1
                shift
                ;;
            -h|--help) usage; return 0 ;;
            --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; return 0 ;;
            --)
                error "'--' is not supported; use --input PATH"
                parse_failed=1
                ;;
            -*) error "unknown option: $arg"; parse_failed=1 ;;
            *)
                error "unexpected positional argument: $arg (use --input PATH)"
                if (( ${#inputs[@]} )); then
                    hint 'the shell may have expanded an unquoted input pattern'
                    hint "quote patterns passed to --input, for example:"
                    operational_continuation stderr \
                        "  $PROGRAM --input '../test/doc*.pdf' --output-dir output"
                fi
                parse_failed=1
                ;;
        esac
    done

    (( parse_failed == 0 )) || return 2
    if [[ -z $mode ]]; then
        error 'choose exactly one output mode: --output FILE, --output-dir DIR, or --replace'
        usage_hint
        return 2
    fi
    if [[ $mode == output ]]; then
        if [[ -z $output_dir ]]; then
            error '--output-dir must not be empty'
            return 2
        fi
        if [[ -L $output_dir ]]; then
            error "output directory must not be a symlink: $output_dir"
            return 2
        fi
        if [[ -e $output_dir && ! -d $output_dir ]]; then
            error "output path exists but is not a directory: $output_dir"
            return 2
        fi
        if [[ -d $output_dir ]]; then
            output_root_key=$(realpath -- "$output_dir") || {
                error "cannot resolve output directory: $output_dir"
                return 2
            }
        else
            output_root_key=$(absolute_path "$output_dir") || {
                error "cannot resolve output directory: $output_dir"
                return 2
            }
        fi
    elif [[ $mode == file ]]; then
        if [[ -z $output_file ]]; then
            error '--output must not be empty'
            return 2
        fi
        if [[ -z ${output_file##*/} ]]; then
            error "--output requires a filename, not a directory path: $output_file"
            return 2
        fi
        if [[ -e $output_file || -L $output_file ]]; then
            error "output destination already exists: $output_file"
            return 2
        fi
        output_parent=${output_file%/*}
        [[ $output_parent != "$output_file" ]] || output_parent=.
        if [[ -L $output_parent ]]; then
            error "output parent directory must not be a symlink: $output_parent"
            return 2
        fi
        if [[ ! -d $output_parent ]]; then
            error "output parent directory does not exist: $output_parent"
            return 2
        fi
    fi
    if (( quality_explicit && detailed_quality )); then
        error 'choose one quality approach: use --quality MODE or detailed options (--max-dpi and --jpeg-recompress), not both'
        return 2
    fi
    if [[ -n $max_dpi && ! $max_dpi =~ ^[1-9][0-9]*$ ]]; then
        error "--max-dpi must be a positive integer: $max_dpi"
        return 2
    fi
    if [[ -n $jpeg_recompress &&
        ! $jpeg_recompress =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
        error "--jpeg-recompress QFactor must be between 0.0 and 1.0: $jpeg_recompress"
        return 2
    fi
    (( detailed_quality )) && quality='detailed'
    case $quality in
        preserve|balanced|small|detailed) ;;
        *)
            error "unsupported quality mode: $quality"
            return 2
            ;;
    esac
    case $clean_scan in
        ''|gentle|standard|strong) ;;
        *)
            error "unsupported scan cleanup mode: $clean_scan"
            return 2
            ;;
    esac
    if [[ -n $clean_scan && $quality_explicit -eq 0 ]]; then
        quality='detailed'
        [[ -n $jpeg_recompress ]] || jpeg_recompress='0.10'
    fi
    case $metadata_mode in
        none|basic|standard|all) ;;
        *)
            error "unsupported metadata mode: $metadata_mode"
            return 2
            ;;
    esac
    if [[ $metadata_mode == all && $(uname -s) != Darwin ]]; then
        error '--preserve-metadata all is currently supported only on macOS'
        return 2
    fi
    if [[ -z $timeout_duration ]]; then
        error '--timeout duration must not be empty'
        return 2
    fi
    if (( jobs_explicit )) && [[ ! $jobs =~ ^([1-9]|1[01])$ ]]; then
        error "--jobs must be an integer from 1 through 11: $jobs"
        return 2
    fi
    if (( jobs_explicit )) && [[ -z $clean_scan ]]; then
        error '--jobs requires --clean-scan'
        return 2
    fi
    if (( reprocess )) && [[ $mode != replace ]]; then
        error '--reprocess requires --replace'
        return 2
    fi
    if (( ${#inputs[@]} == 0 )); then
        error 'at least one --input PATH is required'
        usage_hint
        return 2
    fi
    if [[ $mode == file ]]; then
        if (( recursive )); then
            error '--recursive cannot be used with --output'
            return 2
        fi
        if (( ${#inputs[@]} != 1 )); then
            error '--output requires exactly one input file'
            return 2
        fi
        if [[ -L ${inputs[0]} ]]; then
            error "--output input must not be a symlink: ${inputs[0]}"
            return 2
        fi
        if [[ ! -f ${inputs[0]} ]]; then
            error "--output input must be a regular file: ${inputs[0]}"
            return 2
        fi
        if ! is_pdf_name "${inputs[0]}" &&
            ! { [[ -n $clean_scan ]] && is_raster_image_name "${inputs[0]}"; }; then
            error "--output input must be a PDF, or a raster image with --clean-scan: ${inputs[0]}"
            return 2
        fi
        if ! is_pdf_name "${inputs[0]}" && ! is_pdf_name "$output_file"; then
            error "raster-image input requires a .pdf output filename: $output_file"
            return 2
        fi
    fi

    for arg in "${inputs[@]}"; do
        if [[ -L $arg ]]; then
            warn "skipping symlink: $arg"
        elif [[ -d $arg ]]; then
            directory=$(realpath -- "$arg") || {
                error "cannot resolve input directory: $arg"
                discovery_failed=1
                continue
            }
            discover_directory "$directory" || discovery_failed=1
        elif [[ -f $arg ]]; then
            relative=${arg##*/}
            append_source "$arg" "$relative" || discovery_failed=1
        elif [[ -e $arg ]]; then
            warn "skipping unsupported input: $arg"
        else
            error "input does not exist: $arg"
            discovery_failed=1
        fi
    done

    (( discovery_failed == 0 )) || return 2
    if (( ${#sources[@]} == 0 )); then
        if [[ -n $clean_scan ]]; then
            warn 'no PDF or raster-image files selected for processing'
        else
            warn 'no PDF files selected for processing'
        fi
        return 0
    fi
    script_path=$(realpath -- "$0") || {
        error 'could not resolve the script path for replacement logging'
        return 2
    }
    processing_policy=$(processing_signature "$quality" "$max_dpi" \
        "$jpeg_recompress" "$grayscale" "$clean_scan" "$metadata_mode") || {
        error 'could not determine the replacement processing policy'
        return 2
    }
    verbose "discovered ${#sources[@]} input(s)"
    case $mode in
        file) verbose "output mode: exact file ($output_file)" ;;
        output) verbose "output mode: directory ($output_dir)" ;;
        replace) verbose 'output mode: replace if smaller' ;;
    esac
    if [[ -n $clean_scan ]]; then
        if (( clean_scan_mode_explicit )); then
            verbose "scan cleanup mode: $clean_scan (explicit)"
        else
            verbose "scan cleanup mode: $clean_scan (default)"
        fi
        if (( jobs_explicit )); then
            verbose "scan cleanup workers requested: $jobs (explicit)"
        else
            verbose "scan cleanup workers: automatic (up to $AUTOMATIC_SCAN_JOB_CAP)"
        fi
    else
        verbose 'scan cleanup: disabled'
    fi
    if (( quality_explicit )); then
        verbose "PDF quality: $quality preset (explicit)"
    elif (( detailed_quality )); then
        verbose "PDF quality: detailed (max DPI: ${max_dpi:-none}; JPEG QFactor: ${jpeg_recompress:-pass-through/default encoding})"
    elif [[ -n $clean_scan ]]; then
        verbose "PDF quality: scan-clean defaults (source DPI; JPEG QFactor $jpeg_recompress)"
    else
        verbose 'PDF quality: preserve (default)'
    fi
    if (( grayscale )); then
        verbose 'grayscale: enabled'
    else
        verbose 'grayscale: disabled'
    fi
    if (( metadata_mode_explicit )); then
        verbose "metadata: $metadata_mode (explicit)"
    else
        verbose "metadata: $metadata_mode (default)"
    fi
    verbose "timeout: $timeout_duration"
    if [[ $mode == replace ]]; then
        state_directory=$(replacement_state_directory) || return 2
        log_file=$state_directory/processed_pdfs.log
        old_log_file=${script_path%/*}/processed_pdfs.log
        lookup_log=$log_file
        if (( dry_run )); then
            if [[ ! -e $lookup_log && ! -L $lookup_log && \
                ( -e $old_log_file || -L $old_log_file ) ]]; then
                lookup_log=$old_log_file
            fi
        else
            if [[ -e $log_file || -L $log_file ]]; then
                migrate_replacement_log "$log_file" "$log_file" || return 2
            elif [[ -e $old_log_file || -L $old_log_file ]]; then
                migrate_replacement_log "$old_log_file" "$log_file" || return 2
            fi
        fi
    fi
    if [[ $mode == replace && $reprocess -eq 0 ]]; then
        filter_logged_sources "$lookup_log" "$processing_policy" || return 2
    fi
    if (( ${#sources[@]} == 0 )); then
        return 0
    fi
    plan_actions || return 2

    (( dry_run )) && return 0

    timeout_command=$(find_command timeout gtimeout) || {
        error 'GNU timeout is required (install timeout or gtimeout)'
        return 1
    }
    gs_command=$(find_command gs) || {
        error 'Ghostscript is required (gs was not found)'
        return 1
    }
    if [[ -n $clean_scan ]]; then
        scan_clean_command=$(find_scan_clean_command "$script_path") || {
            error 'scan-clean.sh is required for --clean-scan (no executable sibling or PATH command was found)'
            return 1
        }
        magick_command=$(find_command magick) || {
            error 'ImageMagick is required for --clean-scan (magick was not found)'
            return 1
        }
        i=0
        while (( i < ${#source_types[@]} )); do
            if [[ ${source_types[$i]} == pdf ]]; then
                needs_pdf_scan_tools=1
                break
            fi
            ((i += 1))
        done
    fi
    if (( needs_pdf_scan_tools )); then
        pdfinfo_command=$(find_command pdfinfo) || {
            error 'Poppler is required for --clean-scan (pdfinfo was not found)'
            return 1
        }
        pdfimages_command=$(find_command pdfimages) || {
            error 'Poppler is required for --clean-scan (pdfimages was not found)'
            return 1
        }
        pdftotext_command=$(find_command pdftotext) || {
            error 'Poppler is required for --clean-scan (pdftotext was not found)'
            return 1
        }
        pdfdetach_command=$(find_command pdfdetach) || {
            error 'Poppler is required for --clean-scan (pdfdetach was not found)'
            return 1
        }
        pdftocairo_command=$(find_command pdftocairo) || {
            error 'Poppler is required for --clean-scan (pdftocairo was not found)'
            return 1
        }
        detect_metrics_machine
    fi
    trap cleanup_active_candidate EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    i=0
    while (( i < ${#sources[@]} )); do
        verbose "processing $((i + 1)) of ${#sources[@]}: ${sources[$i]}"
        operational_message stdout "processing: ${sources[$i]}"
        process_source "${sources[$i]}" "${relatives[$i]}" \
            "${destinations[$i]}" "${source_types[$i]}" || {
            failures=1
            ((i += 1))
            continue
        }
        if [[ $mode == replace ]]; then
            if [[ -z $PROCESS_OUTCOME ]]; then
                error "replacement completed without a log outcome: ${sources[$i]}"
                failures=1
            else
                if append_replacement_log "$log_file" "${sources[$i]}" \
                    "$processing_policy" "$PROCESS_OUTCOME" \
                    "$PROCESS_ARTIFACT"; then
                    verbose "recorded replacement outcome: $PROCESS_OUTCOME"
                else
                    failures=1
                fi
            fi
        fi
        ((i += 1))
    done
    trap - EXIT HUP INT TERM
    (( failures == 0 ))
}

if [[ ${PDF_SLIM_TESTING:-0} != 1 ]]; then
    main "$@"
    main_status=$?
    finish_operational_output
    exit "$main_status"
fi
