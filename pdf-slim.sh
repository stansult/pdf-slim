#!/usr/bin/env bash

# Safe PDF size reduction and scan cleanup with explicit input/output modes,
# configurable image quality, reliable conversion, atomic publication,
# metadata preservation, and replacement logging.

set -o nounset

PROGRAM=${0##*/}
VERSION='1.2.0'
LOG_MAGIC='pdf-slim-log-v1'
DEFAULT_IMAGE_INPUT_DPI='300'
MINIMUM_CREDIBLE_IMAGE_DPI='150'

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
  --clean-scan MODE      Improve an image-only scan using gentle, standard, or
                         strong contrast cleanup while retaining color
                         (default with no quality options: source DPI and JPEG
                         QFactor 0.10; --grayscale remains independent)

Options:
  --recursive         Descend into supplied directories
  --reprocess         Reprocess files that match the replacement log; all safety
                      checks remain enabled (requires --replace)
  --timeout DURATION  Per-file conversion timeout (default: 1h)
  --dry-run           Print planned actions; run no Ghostscript and write nothing
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

Full documentation:
  https://github.com/stansult/pdf-slim

Exit status: 0 success, 1 conversion failure, 2 invalid or unsafe request.
EOF
}

usage_hint() {
    cat >&2 <<EOF
Choose how to handle converted PDFs. For the current directory:
  $PROGRAM --input . --output-dir slimmed
  $PROGRAM --input . --replace
For a single PDF:
  $PROGRAM --input original.pdf -o compressed.pdf
For a scanned image:
  $PROGRAM --input scan.jpg -o scan-cleaned.pdf --clean-scan standard

Run '$PROGRAM --help' for full usage.
EOF
}

error() {
    printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
}

warn() {
    printf '%s: warning: %s\n' "$PROGRAM" "$*" >&2
}

hint() {
    printf '%s: hint: %s\n' "$PROGRAM" "$*" >&2
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

file_times() {
    stat -f '%a:%m' -- "$1" 2>/dev/null || stat -c '%X:%Y' -- "$1"
}

file_mtime() {
    stat -f '%m' -- "$1" 2>/dev/null || stat -c '%Y' -- "$1"
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

validate_log_header() {
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
    if [[ $header != "$LOG_MAGIC" ]]; then
        error "replacement log uses an unsupported format: $log_file"
        return 1
    fi
}

ensure_replacement_log() {
    local log_file=$1
    local old_umask

    if [[ -e $log_file || -L $log_file ]]; then
        validate_log_header "$log_file"
        return
    fi
    old_umask=$(umask)
    umask 077
    printf '%s\0' "$LOG_MAGIC" >"$log_file"
    local status=$?
    umask "$old_umask"
    (( status == 0 )) || {
        error "could not create replacement log: $log_file"
        return 1
    }
}

replacement_log_contains() {
    local log_file=$1
    local source=$2
    local canonical size mtime header record_path record_size record_mtime
    local status=1

    [[ -e $log_file || -L $log_file ]] || return 1
    canonical=$(realpath -- "$source") || return 2
    size=$(file_size "$source") || return 2
    mtime=$(file_mtime "$source") || return 2

    acquire_log_lock "$log_file" || return 2
    if ! validate_log_header "$log_file"; then
        release_log_lock
        return 2
    fi
    exec 3<"$log_file" || {
        release_log_lock
        return 2
    }
    IFS= read -r -d '' header <&3 || status=2
    while (( status != 2 )) && IFS= read -r -d '' record_path <&3; do
        IFS= read -r -d '' record_size <&3 || { status=2; break; }
        IFS= read -r -d '' record_mtime <&3 || { status=2; break; }
        if [[ $record_path == "$canonical" && $record_size == "$size" && \
            $record_mtime == "$mtime" ]]; then
            status=0
            break
        fi
    done
    exec 3<&-
    release_log_lock
    if (( status == 2 )); then
        error "replacement log contains an incomplete record: $log_file"
    fi
    return "$status"
}

append_replacement_log() {
    local log_file=$1
    local source=$2
    local canonical size mtime

    canonical=$(realpath -- "$source") || return 1
    size=$(file_size "$source") || return 1
    mtime=$(file_mtime "$source") || return 1
    acquire_log_lock "$log_file" || return 1
    if ! ensure_replacement_log "$log_file"; then
        release_log_lock
        return 1
    fi
    if ! printf '%s\0%s\0%s\0' "$canonical" "$size" "$mtime" >>"$log_file"; then
        error "could not append replacement log: $log_file"
        release_log_lock
        return 1
    fi
    release_log_lock
}

filter_logged_sources() {
    local log_file=$1
    local i status
    local -a kept_sources=()
    local -a kept_source_keys=()
    local -a kept_relatives=()
    local -a kept_source_types=()

    [[ -e $log_file || -L $log_file ]] || return 0
    i=0
    while (( i < ${#sources[@]} )); do
        replacement_log_contains "$log_file" "${sources[$i]}"
        status=$?
        if (( status == 0 )); then
            printf 'skipped unchanged file recorded as processed: %s\n' "${sources[$i]}"
        elif (( status == 1 )); then
            kept_sources[${#kept_sources[@]}]=${sources[$i]}
            kept_source_keys[${#kept_source_keys[@]}]=${source_keys[$i]}
            kept_relatives[${#kept_relatives[@]}]=${relatives[$i]}
            kept_source_types[${#kept_source_types[@]}]=${source_types[$i]}
        else
            return 1
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
    [[ -z $SCAN_COMMAND_OUTPUT ]] || printf '%s\n' "$SCAN_COMMAND_OUTPUT" >&2
    return 1
}

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
    local x_dpi y_dpi page_width page_height minimum residual
    local i
    local -a image_counts=()
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
    while read -r -a fields; do
        [[ ${fields[0]:-} == Page && ${fields[2]:-} == size: ]] || continue
        page=${fields[1]:-}
        page_width=${fields[3]:-}
        page_height=${fields[5]:-}
        if [[ $page =~ ^[1-9][0-9]*$ &&
            $page_width =~ ^[0-9]+([.][0-9]+)?$ &&
            $page_height =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            SCAN_PAGE_WIDTH[page]=$page_width
            SCAN_PAGE_HEIGHT[page]=$page_height
        fi
    done <<<"$SCAN_COMMAND_OUTPUT"
    i=1
    while (( i <= pages )); do
        if [[ -z ${SCAN_PAGE_WIDTH[$i]:-} || -z ${SCAN_PAGE_HEIGHT[$i]:-} ]]; then
            error "could not determine page geometry for scan cleanup (page $i): $source"
            return 1
        fi
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
    while read -r -a fields; do
        page=${fields[0]:-}
        [[ $page =~ ^[1-9][0-9]*$ ]] || continue
        type=${fields[2]:-}
        x_dpi=${fields[12]:-}
        y_dpi=${fields[13]:-}
        image_counts[page]=$((${image_counts[page]:-0} + 1))
        if [[ $type != image || ! $x_dpi =~ ^[1-9][0-9]*$ ||
            ! $y_dpi =~ ^[1-9][0-9]*$ ]]; then
            error "scan cleanup requires exactly one ordinary image per page: $source"
            return 1
        fi
        SCAN_X_DPI[page]=$x_dpi
        SCAN_Y_DPI[page]=$y_dpi
    done <<<"$SCAN_COMMAND_OUTPUT"
    i=1
    while (( i <= pages )); do
        if (( ${image_counts[$i]:-0} != 1 )); then
            error "scan cleanup requires exactly one image on every page (page $i): $source"
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
    local page rendered cleaned dimensions pixel_width pixel_height
    local output_x_dpi output_y_dpi
    local -a assembly_args=()

    inspect_scan_pdf "$source" "$scan_directory" "$timeout_command" \
        "$timeout_duration" "$gs_command" "$magick_command" \
        "$pdfinfo_command" "$pdfimages_command" "$pdftotext_command" \
        "$pdfdetach_command" || return 1
    mkdir "$scan_directory/rendered" "$scan_directory/cleaned" || return 1
    page=1
    while (( page <= SCAN_PAGE_COUNT )); do
        rendered=$scan_directory/rendered/page-$page
        cleaned=$scan_directory/cleaned/page-$page.png
        run_scan_command 'scan page rendering' "$source" "$timeout_command" \
            "$timeout_duration" "$pdftocairo_command" -png -singlefile \
            -f "$page" -l "$page" -rx "${SCAN_X_DPI[$page]}" \
            -ry "${SCAN_Y_DPI[$page]}" "$source" "$rendered" || return 1
        if [[ ! -s $rendered.png ]]; then
            error "scan renderer produced no page image (page $page): $source"
            return 1
        fi
        run_scan_command 'scan contrast cleanup' "$source" "$timeout_command" \
            "$timeout_duration" "$scan_clean_command" \
            --input "$rendered.png" --output "$cleaned" \
            --mode "$cleanup_mode" --strip-metadata \
            --timeout "$timeout_duration" || return 1
        if [[ ! -s $cleaned ]]; then
            error "scan cleanup produced no page image (page $page): $source"
            return 1
        fi
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
            -units PixelsPerInch
            -density "${output_x_dpi}x${output_y_dpi}"
            "$cleaned"
        )
        ((page += 1))
    done
    run_scan_command 'cleaned PDF assembly' "$source" "$timeout_command" \
        "$timeout_duration" "$magick_command" "${assembly_args[@]}" \
        -compress Zip "$cleaned_pdf" || return 1
    if [[ ! -f $cleaned_pdf || -L $cleaned_pdf || ! -s $cleaned_pdf ]]; then
        error "scan cleanup produced no valid nonempty PDF: $source"
        return 1
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

    run_scan_command 'image scan cleanup' "$source" "$timeout_command" \
        "$timeout_duration" "$scan_clean_command" \
        --input "$source" --output "$cleaned_image" \
        --mode "$cleanup_mode" --strip-metadata \
        --timeout "$timeout_duration" || return 1
    if [[ ! -f $cleaned_image || -L $cleaned_image || ! -s $cleaned_image ]]; then
        error "scan cleanup produced no valid image: $source"
        return 1
    fi
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
            printf '%s\n' "$output" >&2
        fi
        remove_candidate "$candidate"
        return 1
    fi

    if [[ ! -f $candidate || -L $candidate || ! -s $candidate ]]; then
        error "Ghostscript produced no valid nonempty PDF candidate: $source"
        if [[ -n $output ]]; then
            printf '%s\n' "$output" >&2
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
            printf 'would clean scan (%s): %s\n' "$clean_scan" "$source"
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
                printf 'would convert: %s -> %s\n' "$source" "$destination"
            fi
        elif [[ $mode == file ]]; then
            destinations[${#destinations[@]}]=$output_file
            if (( dry_run )); then
                printf 'would convert: %s -> %s\n' "$source" "$output_file"
            fi
        else
            destinations[${#destinations[@]}]=$source
            if (( dry_run )); then
                printf 'would replace if smaller: %s\n' "$source"
            fi
        fi
        ((i += 1))
    done

    (( failures == 0 ))
}

clear_active_files() {
    remove_candidate "${ACTIVE_CANDIDATE:-}"
    remove_candidate "${ACTIVE_METADATA_REFERENCE:-}"
    remove_scan_directory "${ACTIVE_SCAN_DIRECTORY:-}"
    ACTIVE_CANDIDATE=''
    ACTIVE_METADATA_REFERENCE=''
    ACTIVE_SCAN_DIRECTORY=''
    release_log_lock
}

process_source() {
    local source=$1
    local relative=$2
    local destination=$3
    local source_type=${4:-pdf}
    local candidate='' candidate_dir source_before source_after
    local timestamp_reference=''
    local scan_directory='' conversion_source=$source
    local original_size candidate_size

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
    source_before=$(file_identity "$source") || {
        error "could not inspect source before conversion: $source"
        clear_active_files
        return 1
    }
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
                "$scan_clean_command"
        fi || {
            clear_active_files
            return 1
        }
    fi
    convert_pdf "$conversion_source" "$candidate" "$timeout_command" "$gs_command" \
        "$timeout_duration" "$grayscale" "$quality" "$max_dpi" \
        "$jpeg_recompress" || {
        clear_active_files
        return 1
    }
    remove_scan_directory "$scan_directory" || {
        clear_active_files
        return 1
    }
    ACTIVE_SCAN_DIRECTORY=''
    source_after=$(file_identity "$source") || source_after='missing'
    if [[ $source_before != "$source_after" ]]; then
        error "source changed during conversion; leaving it untouched: $source"
        clear_active_files
        return 1
    fi
    finalize_candidate_metadata "$source" "$candidate" "$metadata_mode" \
        "$timestamp_reference" || {
        error "could not preserve requested metadata: $source"
        clear_active_files
        return 1
    }

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
        if (( candidate_size >= original_size )); then
            printf 'kept original (converted file was not smaller): %s\n' "$source"
            clear_active_files
            return 0
        fi
    fi

    if [[ $mode != replace && ( -e $destination || -L $destination ) ]]; then
        error "output destination appeared during conversion: $destination"
        clear_active_files
        return 1
    fi
    if [[ $mode == replace ]]; then
        source_after=$(file_identity "$source") || source_after='missing'
        if [[ $source_before != "$source_after" ]]; then
            error "source changed before replacement; leaving it untouched: $source"
            clear_active_files
            return 1
        fi
    fi
    if [[ $mode == replace ]]; then
        mv -- "$candidate" "$destination" || {
            error "could not publish converted PDF: $destination"
            clear_active_files
            return 1
        }
    else
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
        printf 'replaced: %s\n' "$source"
    else
        printf 'created: %s\n' "$destination"
    fi
}

cleanup_active_candidate() {
    local status=$?
    clear_active_files
    exit "$status"
}

main() {
    local output_dir=''
    local output_file=''
    local mode=''
    local timeout_duration='1h'
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
    local log_file script_path
    local timeout_command gs_command magick_command pdfinfo_command
    local pdfimages_command pdftotext_command pdfdetach_command
    local pdftocairo_command scan_clean_command
    local failures=0 i needs_pdf_scan_tools=0
    ACTIVE_CANDIDATE=''
    ACTIVE_METADATA_REFERENCE=''
    ACTIVE_SCAN_DIRECTORY=''
    ACTIVE_LOG_LOCK=''

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
            --dry-run) dry_run=1 ;;
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
                if (( $# == 0 )); then
                    error '--clean-scan requires a mode argument'
                    parse_failed=1
                    break
                fi
                clean_scan=$1
                shift
                ;;
            --preserve-metadata)
                if (( $# == 0 )); then
                    error '--preserve-metadata requires a mode argument'
                    parse_failed=1
                    break
                fi
                metadata_mode=$1
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
                    printf "  %s --input '../test/doc*.pdf' --output-dir output\n" \
                        "$PROGRAM" >&2
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
    log_file=${script_path%/*}/processed_pdfs.log
    if [[ $mode == replace && $reprocess -eq 0 ]]; then
        filter_logged_sources "$log_file" || return 2
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
    fi
    trap cleanup_active_candidate EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    i=0
    while (( i < ${#sources[@]} )); do
        process_source "${sources[$i]}" "${relatives[$i]}" \
            "${destinations[$i]}" "${source_types[$i]}" || {
            failures=1
            ((i += 1))
            continue
        }
        if [[ $mode == replace ]]; then
            append_replacement_log "$log_file" "${sources[$i]}" || failures=1
        fi
        ((i += 1))
    done
    trap - EXIT HUP INT TERM
    (( failures == 0 ))
}

if [[ ${PDF_SLIM_TESTING:-0} != 1 ]]; then
    main "$@"
fi
