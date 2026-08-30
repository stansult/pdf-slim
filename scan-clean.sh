#!/usr/bin/env bash

# Adaptive cleanup for photographed or scanned document images, with safe
# single-file and nonrecursive batch output publication.

set -o nounset

PROGRAM=${0##*/}
VERSION='1.0.0'
DEFAULT_TIMEOUT='1h'
DEFAULT_MODE='standard'
DEFAULT_JPEG_QUALITY='95'
DEFAULT_BACKGROUND='white'

usage() {
    cat <<EOF
Usage: $PROGRAM [options]

Input:
  -i, --input PATH       One image, nonrecursive directory, or quoted glob

Output:
  -o, --output FILE      Exact output filename (one selected image only)
  --output-dir DIR       Output directory, required when multiple images match
  -O, --overwrite        Atomically replace existing output files

Cleanup:
  -m, --mode MODE        gentle, standard (default), or strong
  --all-modes            Generate gentle, standard, and strong variants

Image options:
  --jpeg-quality N       JPEG output quality, 1-100 (default: 95)
  --background COLOR     Transparency background for JPEG (default: white)
  --strip-metadata       Remove image metadata instead of preserving what the
                         output format supports

Other options:
  --timeout DURATION     Per-image command timeout (default: 1h)
  --dry-run              Inspect inputs and print actions without writing output
  -h, --help             Show this help and exit
  --version              Show the version and exit

With one selected image and no output option, output is created beside the
input as NAME-MODE.EXT. Existing automatic names receive a shared numeric index,
for example NAME-2-GENTLE.EXT through NAME-2-STRONG.EXT. Batch input requires
--output-dir; that directory and missing parents are created safely. An exact
output filename selects its image format, so PNG-to-JPEG conversion is allowed.
PNG and other alpha-capable outputs retain transparency; JPEG flattens it onto
--background. Symlinks, vector documents, animations, and multi-frame images are
not processed. Broad directory and glob inputs warn about and skip non-images.

Exit status: 0 success, 1 one or more images failed, 2 invalid/unsafe request.
EOF
}

error() {
    printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
}

warn() {
    printf '%s: warning: %s\n' "$PROGRAM" "$*" >&2
}

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

file_identity() {
    stat -f '%d:%i:%z:%m:%c' -- "$1" 2>/dev/null || \
        stat -c '%d:%i:%s:%Y:%Z' -- "$1"
}

expand_input_pattern() (
    local pattern=$1
    local IFS=
    local -a matches=()

    set +o noglob
    shopt -s nullglob
    shopt -u failglob dotglob nocaseglob
    # shellcheck disable=SC2206
    matches=( $pattern )
    (( ${#matches[@]} )) && printf '%s\0' "${matches[@]}"
)

remove_temp_directory() {
    local directory=$1

    [[ -n $directory ]] || return 0
    if [[ ${directory##*/} != .scan-clean.* ]]; then
        error "refusing to remove unexpected temporary directory: $directory"
        return 1
    fi
    if [[ -e $directory || -L $directory ]]; then
        rm -rf -- "$directory"
    fi
}

clear_active_temp_directories() {
    local directory

    for directory in "${ACTIVE_TEMP_DIRECTORIES[@]}"; do
        remove_temp_directory "$directory" || true
    done
    ACTIVE_TEMP_DIRECTORIES=()
}

cleanup_on_exit() {
    local status=$?
    clear_active_temp_directories
    exit "$status"
}

run_command() {
    local stage=$1
    local source=$2
    local status
    shift 2

    COMMAND_OUTPUT=$("$timeout_command" -- "$timeout_duration" "$@" 2>&1)
    status=$?
    if (( status == 0 )); then
        return 0
    fi
    if (( status == 124 )); then
        error "$stage timed out after $timeout_duration: $source"
    else
        error "$stage failed with status $status: $source"
    fi
    [[ -z $COMMAND_OUTPUT ]] || printf '%s\n' "$COMMAND_OUTPUT" >&2
    return 1
}

is_forbidden_format() {
    case $1 in
        AI|EPDF|EPI|EPS|EPS2|EPS3|EPSF|EPSI|HTML|MVG|MSL|PDF|PS|PS2|PS3|SVG|SVGZ|TEXT|XPS)
            return 0
            ;;
        *) return 1 ;;
    esac
}

probe_image() {
    local source=$1
    local output status line_count

    output=$("$timeout_command" -- "$timeout_duration" "$magick_command" \
        identify -quiet -format '%m|%n|%w|%h|%[mime:type]|%[orientation]|%[profiles]\n' \
        "$source" 2>/dev/null)
    status=$?
    (( status == 0 )) || return 1
    line_count=$(printf '%s\n' "$output" | awk 'NF { count += 1 } END { print count + 0 }')
    (( line_count == 1 )) || return 1
    IFS='|' read -r IMAGE_FORMAT IMAGE_FRAMES IMAGE_WIDTH IMAGE_HEIGHT \
        IMAGE_MIME IMAGE_ORIENTATION IMAGE_PROFILES <<<"$output"
    [[ $IMAGE_FRAMES == 1 && $IMAGE_WIDTH =~ ^[1-9][0-9]*$ &&
        $IMAGE_HEIGHT =~ ^[1-9][0-9]*$ && $IMAGE_MIME == image/* ]] || return 1
    is_forbidden_format "$IMAGE_FORMAT" && return 1
    case $IMAGE_ORIENTATION in
        LeftTop|RightTop|RightBottom|LeftBottom)
            IMAGE_ORIENTED_WIDTH=$IMAGE_HEIGHT
            IMAGE_ORIENTED_HEIGHT=$IMAGE_WIDTH
            ;;
        *)
            IMAGE_ORIENTED_WIDTH=$IMAGE_WIDTH
            IMAGE_ORIENTED_HEIGHT=$IMAGE_HEIGHT
            ;;
    esac
}

append_image() {
    local source=$1
    local broad_discovery=$2
    local canonical existing
    local i

    if [[ -L $source ]]; then
        warn "skipping symlink: $source"
        return 0
    fi
    if [[ ! -f $source ]]; then
        if (( broad_discovery )); then
            warn "skipping non-file: $source"
            return 0
        fi
        error "input is not a regular file: $source"
        return 1
    fi
    if ! probe_image "$source"; then
        if (( broad_discovery )); then
            warn "skipping unsupported, multi-frame, or unreadable image: $source"
            return 0
        fi
        error "input is not a supported single-frame raster image: $source"
        return 1
    fi
    canonical=$(realpath -- "$source") || {
        error "cannot resolve input: $source"
        return 1
    }
    i=0
    while (( i < ${#source_keys[@]} )); do
        existing=${source_keys[$i]}
        [[ $existing != "$canonical" ]] || return 0
        ((i += 1))
    done
    sources[${#sources[@]}]=$source
    source_keys[${#source_keys[@]}]=$canonical
    source_formats[${#source_formats[@]}]=$IMAGE_FORMAT
    source_widths[${#source_widths[@]}]=$IMAGE_ORIENTED_WIDTH
    source_heights[${#source_heights[@]}]=$IMAGE_ORIENTED_HEIGHT
    source_profiles[${#source_profiles[@]}]=$IMAGE_PROFILES
}

discover_directory() {
    local directory=$1
    local path

    while IFS= read -r -d '' path; do
        append_image "$path" 1 || return 1
    done < <(find -P "$directory" -mindepth 1 -maxdepth 1 \
        \( -type l -o -type f \) -print0)
}

split_image_name() {
    local source=$1
    local format=$2
    local name=${source##*/}

    if [[ $name == *.* && ${name%.*} != '' ]]; then
        IMAGE_STEM=${name%.*}
        IMAGE_EXTENSION=.${name##*.}
        return
    fi
    IMAGE_STEM=$name
    case $format in
        JPEG) IMAGE_EXTENSION='.jpg' ;;
        TIFF) IMAGE_EXTENSION='.tiff' ;;
        *)
            IMAGE_EXTENSION=$(printf '%s' ".$format" | tr '[:upper:]' '[:lower:]')
            ;;
    esac
}

destination_key_is_reserved() {
    local key=$1
    local existing

    for existing in "${reserved_destination_keys[@]}"; do
        [[ $existing != "$key" ]] || return 0
    done
    return 1
}

destination_can_be_used() {
    local destination=$1
    local allow_existing=$2
    local key

    key=$(absolute_path "$destination") || return 1
    destination_key_is_reserved "$key" && return 1
    if [[ -L $destination ]]; then
        return 1
    fi
    if [[ -e $destination ]]; then
        (( allow_existing )) && [[ -f $destination ]] || return 1
    fi
}

reserve_destination() {
    local destination=$1
    local key

    key=$(absolute_path "$destination") || return 1
    reserved_destination_keys[${#reserved_destination_keys[@]}]=$key
    if [[ $key == "$CURRENT_SOURCE_KEY" ]]; then
        error "output must not resolve to its input: $destination"
        return 1
    fi
}

destination_for_mode() {
    local source_index=$1
    local selected_mode=$2
    local group_index=$3
    local target_directory=$4
    local marker=''

    split_image_name "${sources[$source_index]}" "${source_formats[$source_index]}"
    (( group_index <= 1 )) || marker=-$group_index
    printf '%s/%s%s-%s%s\n' "$target_directory" "$IMAGE_STEM" "$marker" \
        "$selected_mode" "$IMAGE_EXTENSION"
}

plan_source_destinations() {
    local source_index=$1
    local target_directory=$2
    local group_index=1 selected_mode destination usable
    local -a selected_modes=()
    local -a proposed=()

    CURRENT_SOURCE_KEY=${source_keys[$source_index]}
    if (( all_modes )); then
        selected_modes=(gentle standard strong)
    else
        selected_modes=("$mode")
    fi

    while :; do
        proposed=()
        usable=1
        for selected_mode in "${selected_modes[@]}"; do
            destination=$(destination_for_mode "$source_index" "$selected_mode" \
                "$group_index" "$target_directory")
            if ! destination_can_be_used "$destination" "$overwrite"; then
                usable=0
                break
            fi
            proposed[${#proposed[@]}]=$destination
        done
        (( usable )) && break
        if (( overwrite )); then
            error "output destination is unsafe or collides with another input: $destination"
            return 1
        fi
        ((group_index += 1))
    done

    for destination in "${proposed[@]}"; do
        reserve_destination "$destination" || return 1
    done
    if (( all_modes )); then
        gentle_destinations[source_index]=${proposed[0]}
        standard_destinations[source_index]=${proposed[1]}
        strong_destinations[source_index]=${proposed[2]}
    else
        case $mode in
            gentle) gentle_destinations[source_index]=${proposed[0]} ;;
            standard) standard_destinations[source_index]=${proposed[0]} ;;
            strong) strong_destinations[source_index]=${proposed[0]} ;;
        esac
    fi
}

prepare_output_directory() {
    local directory=$1
    local create_missing=$2
    local require_existing=$3
    local absolute current='' remaining component

    absolute=$(absolute_path "$directory") || return 1
    remaining=${absolute#/}
    while [[ -n $remaining ]]; do
        if [[ $remaining == */* ]]; then
            component=${remaining%%/*}
            remaining=${remaining#*/}
        else
            component=$remaining
            remaining=''
        fi
        current=$current/$component
        if [[ -L $current ]]; then
            error "refusing symlink in output directory path: $current"
            return 1
        fi
        if [[ -e $current && ! -d $current ]]; then
            error "output directory component is not a directory: $current"
            return 1
        fi
        if [[ ! -d $current ]]; then
            if (( create_missing )); then
                mkdir "$current" || return 1
            elif (( require_existing )); then
                error "output directory does not exist: $current"
                return 1
            else
                return 0
            fi
        fi
    done
}

detect_background_cast() {
    local source=$1
    local dominant_color red green blue minimum maximum histogram

    run_command 'background inspection' "$source" "$magick_command" "$source" \
        -resize '10%' -colors 12 -depth 8 -format %c histogram:info:- || return 1
    histogram=$COMMAND_OUTPUT
    dominant_color=$(printf '%s\n' "$histogram" | LC_ALL=C sort -nr | sed -n \
        '1{s/.*(\([0-9][0-9]*\),\([0-9][0-9]*\),\([0-9][0-9]*\)[,)].*/\1 \2 \3/p;}')
    read -r red green blue <<<"$dominant_color"
    if [[ ! ${red:-} =~ ^[0-9]+$ || ! ${green:-} =~ ^[0-9]+$ ||
        ! ${blue:-} =~ ^[0-9]+$ ]]; then
        error "could not estimate the document background color: $source"
        return 1
    fi
    minimum=$red
    maximum=$red
    (( green < minimum )) && minimum=$green
    (( blue < minimum )) && minimum=$blue
    (( green > maximum )) && maximum=$green
    (( blue > maximum )) && maximum=$blue
    if (( maximum - minimum > 10 )); then
        NORMALIZATION_ARGS=(-channel RGB -contrast-stretch '0x0.5%' +channel)
    else
        NORMALIZATION_ARGS=()
    fi
}

is_jpeg_destination() {
    local extension=${1##*.}
    extension=$(printf '%s' "$extension" | tr '[:upper:]' '[:lower:]')
    case $extension in
        jpg|jpeg|jpe) return 0 ;;
        *) return 1 ;;
    esac
}

has_forbidden_output_extension() {
    local extension=${1##*.}

    extension=$(printf '%s' "$extension" | tr '[:lower:]' '[:upper:]')
    is_forbidden_format "$extension"
}

levels_for_mode() {
    case $1 in
        gentle) printf '%s\n' '8%,96%' ;;
        standard) printf '%s\n' '12%,94%' ;;
        strong) printf '%s\n' '16%,92%' ;;
    esac
}

validate_candidate() {
    local candidate=$1
    local expected_width=$2
    local expected_height=$3

    if [[ ! -f $candidate || -L $candidate || ! -s $candidate ]]; then
        error "image cleanup produced no valid nonempty output: $candidate"
        return 1
    fi
    if ! probe_image "$candidate"; then
        error "image cleanup produced an unsupported or multi-frame output: $candidate"
        return 1
    fi
    if [[ $IMAGE_ORIENTED_WIDTH != "$expected_width" ||
        $IMAGE_ORIENTED_HEIGHT != "$expected_height" ]]; then
        error "image dimensions changed unexpectedly: $candidate"
        return 1
    fi
}

process_source() {
    local source_index=$1
    local source=${sources[$source_index]}
    local source_before source_after selected_mode destination parent temp_directory
    local candidate levels icc_profile=''
    local -a selected_modes=()
    local -a candidate_files=()
    local -a candidate_destinations=()
    local -a candidate_directories=()
    local -a image_args=()
    local i

    if [[ -n ${gentle_destinations[$source_index]:-} ]]; then
        selected_modes[${#selected_modes[@]}]=gentle
    fi
    if [[ -n ${standard_destinations[$source_index]:-} ]]; then
        selected_modes[${#selected_modes[@]}]=standard
    fi
    if [[ -n ${strong_destinations[$source_index]:-} ]]; then
        selected_modes[${#selected_modes[@]}]=strong
    fi

    source_before=$(file_identity "$source") || {
        error "could not inspect input before cleanup: $source"
        return 1
    }
    detect_background_cast "$source" || return 1
    for selected_mode in "${selected_modes[@]}"; do
        case $selected_mode in
            gentle) destination=${gentle_destinations[$source_index]} ;;
            standard) destination=${standard_destinations[$source_index]} ;;
            strong) destination=${strong_destinations[$source_index]} ;;
        esac
        parent=${destination%/*}
        [[ $parent != "$destination" ]] || parent=.
        temp_directory=$(mktemp -d "$parent/.scan-clean.XXXXXX") || {
            error "could not create temporary output directory beside: $destination"
            clear_active_temp_directories
            return 1
        }
        ACTIVE_TEMP_DIRECTORIES[${#ACTIVE_TEMP_DIRECTORIES[@]}]=$temp_directory
        candidate=$temp_directory/${destination##*/}
        if (( ! strip_metadata )) &&
            [[ ,${source_profiles[$source_index]}, == *,[iI][cC][cC],* ]]; then
            icc_profile=$temp_directory/source.icc
            run_command 'ICC profile extraction' "$source" \
                "$magick_command" "$source" "$icc_profile" || {
                clear_active_temp_directories
                return 1
            }
        else
            icc_profile=''
        fi
        levels=$(levels_for_mode "$selected_mode")
        image_args=(
            "$source"
            -auto-orient
            "${NORMALIZATION_ARGS[@]}"
            -colorspace Lab
            -channel R
            -level "$levels"
            +channel
            -colorspace sRGB
        )
        if is_jpeg_destination "$destination"; then
            image_args+=(
                -background "$background"
                -alpha remove
                -alpha off
                -quality "$jpeg_quality"
            )
        fi
        (( strip_metadata )) && image_args+=(-strip)
        [[ -z $icc_profile ]] || image_args+=(-profile "$icc_profile")
        image_args+=("$candidate")
        run_command "cleanup mode $selected_mode" "$source" \
            "$magick_command" "${image_args[@]}" || {
            clear_active_temp_directories
            return 1
        }
        validate_candidate "$candidate" "${source_widths[$source_index]}" \
            "${source_heights[$source_index]}" || {
            clear_active_temp_directories
            return 1
        }
        candidate_files[${#candidate_files[@]}]=$candidate
        candidate_destinations[${#candidate_destinations[@]}]=$destination
        candidate_directories[${#candidate_directories[@]}]=$temp_directory
    done

    source_after=$(file_identity "$source") || source_after='missing'
    if [[ $source_before != "$source_after" ]]; then
        error "input changed during cleanup; leaving outputs unpublished: $source"
        clear_active_temp_directories
        return 1
    fi
    for destination in "${candidate_destinations[@]}"; do
        if [[ -L $destination || ( -e $destination &&
            ( $overwrite -eq 0 || ! -f $destination ) ) ]]; then
            error "output destination became unsafe during cleanup: $destination"
            clear_active_temp_directories
            return 1
        fi
    done

    i=0
    while (( i < ${#candidate_files[@]} )); do
        candidate=${candidate_files[$i]}
        destination=${candidate_destinations[$i]}
        if (( overwrite )); then
            mv -- "$candidate" "$destination"
        else
            mv -n -- "$candidate" "$destination"
        fi
        if [[ -e $candidate || -L $candidate || ! -f $destination ||
            -L $destination || ! -s $destination ]]; then
            error "could not publish cleaned image safely: $destination"
            clear_active_temp_directories
            return 1
        fi
        if (( overwrite )); then
            printf 'overwritten: %s\n' "$destination"
        else
            printf 'created: %s\n' "$destination"
        fi
        remove_temp_directory "${candidate_directories[$i]}" || true
        ((i += 1))
    done
    ACTIVE_TEMP_DIRECTORIES=()
}

main() {
    local input_spec='' output_file='' output_dir=''
    local mode=$DEFAULT_MODE mode_explicit=0 all_modes=0 overwrite=0
    local jpeg_quality=$DEFAULT_JPEG_QUALITY background=$DEFAULT_BACKGROUND
    local strip_metadata=0 timeout_duration=$DEFAULT_TIMEOUT dry_run=0
    local arg match path directory parent target_directory destination
    local parse_failed=0 pattern_found=0 discovery_failed=0 broad_input=0
    local timeout_command magick_command
    local i failures=0
    local -a sources=()
    local -a source_keys=()
    local -a source_formats=()
    local -a source_widths=()
    local -a source_heights=()
    local -a source_profiles=()
    local -a reserved_destination_keys=()
    local -a gentle_destinations=()
    local -a standard_destinations=()
    local -a strong_destinations=()
    ACTIVE_TEMP_DIRECTORIES=()

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
                if [[ -n $input_spec ]]; then
                    error '--input may be specified only once'
                    parse_failed=1
                fi
                input_spec=$1
                shift
                ;;
            -o|--output)
                if (( $# == 0 )); then
                    error "$arg requires a filename argument"
                    parse_failed=1
                    break
                fi
                output_file=$1
                shift
                ;;
            --output-dir)
                if (( $# == 0 )); then
                    error '--output-dir requires a directory argument'
                    parse_failed=1
                    break
                fi
                if [[ -z $1 ]]; then
                    error '--output-dir must not be empty'
                    parse_failed=1
                fi
                output_dir=$1
                shift
                ;;
            -O|--overwrite) overwrite=1 ;;
            -m|--mode)
                if (( $# == 0 )); then
                    error "$arg requires a mode argument"
                    parse_failed=1
                    break
                fi
                mode=$1
                mode_explicit=1
                shift
                ;;
            --all-modes) all_modes=1 ;;
            --jpeg-quality)
                if (( $# == 0 )); then
                    error '--jpeg-quality requires an integer argument'
                    parse_failed=1
                    break
                fi
                jpeg_quality=$1
                shift
                ;;
            --background)
                if (( $# == 0 )); then
                    error '--background requires a color argument'
                    parse_failed=1
                    break
                fi
                background=$1
                shift
                ;;
            --strip-metadata) strip_metadata=1 ;;
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
            -h|--help) usage; return 0 ;;
            --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; return 0 ;;
            -*) error "unknown option: $arg"; parse_failed=1 ;;
            *)
                error "unexpected positional argument: $arg (use --input PATH)"
                parse_failed=1
                ;;
        esac
    done
    (( parse_failed == 0 )) || return 2
    [[ -n $input_spec ]] || { error '--input is required'; return 2; }
    if [[ -n $output_file && -n $output_dir ]]; then
        error '--output and --output-dir are mutually exclusive'
        return 2
    fi
    if (( all_modes && mode_explicit )); then
        error '--all-modes cannot be combined with --mode'
        return 2
    fi
    if (( all_modes )) && [[ -n $output_file ]]; then
        error '--all-modes cannot be combined with --output'
        return 2
    fi
    case $mode in
        gentle|standard|strong) ;;
        *) error "unsupported cleanup mode: $mode"; return 2 ;;
    esac
    if [[ ! $jpeg_quality =~ ^[1-9][0-9]*$ ]] ||
        (( jpeg_quality < 1 || jpeg_quality > 100 )); then
        error "--jpeg-quality must be an integer from 1 through 100: $jpeg_quality"
        return 2
    fi
    [[ -n $background ]] || { error '--background must not be empty'; return 2; }
    [[ -n $timeout_duration ]] || { error '--timeout must not be empty'; return 2; }

    timeout_command=$(find_command timeout gtimeout) || {
        error 'GNU timeout is required (install timeout or gtimeout)'
        return 1
    }
    if ! "$timeout_command" -- "$timeout_duration" true >/dev/null 2>&1; then
        error "--timeout is not a valid GNU timeout duration: $timeout_duration"
        return 2
    fi
    magick_command=$(find_command magick) || {
        error 'ImageMagick is required (magick was not found)'
        return 1
    }
    if ! run_command 'background color validation' "$background" \
        "$magick_command" -size 1x1 "xc:$background" null:; then
        error "--background is not a valid ImageMagick color: $background"
        return 2
    fi
    if [[ -n $COMMAND_OUTPUT ]]; then
        printf '%s\n' "$COMMAND_OUTPUT" >&2
        error "--background is not a valid ImageMagick color: $background"
        return 2
    fi

    if [[ -e $input_spec || -L $input_spec ]]; then
        if [[ -d $input_spec && ! -L $input_spec ]]; then
            broad_input=1
            directory=$(realpath -- "$input_spec") || {
                error "cannot resolve input directory: $input_spec"
                return 2
            }
            discover_directory "$directory" || discovery_failed=1
        else
            append_image "$input_spec" 0 || discovery_failed=1
        fi
    elif [[ $input_spec == *'*'* || $input_spec == *'?'* || $input_spec == *'['* ]]; then
        broad_input=1
        while IFS= read -r -d '' match; do
            pattern_found=1
            if [[ -d $match && ! -L $match ]]; then
                directory=$(realpath -- "$match") || {
                    error "cannot resolve matched directory: $match"
                    discovery_failed=1
                    continue
                }
                discover_directory "$directory" || discovery_failed=1
            else
                append_image "$match" 1 || discovery_failed=1
            fi
        done < <(expand_input_pattern "$input_spec")
        if (( ! pattern_found )); then
            error "input pattern matched no paths: $input_spec"
            return 2
        fi
    else
        error "input does not exist: $input_spec"
        return 2
    fi
    (( discovery_failed == 0 )) || return 2
    if (( ${#sources[@]} == 0 )); then
        if (( broad_input )) && [[ -d $input_spec ]]; then
            warn 'no images selected for processing'
            return 0
        fi
        error 'no supported images selected for processing'
        return 2
    fi
    if [[ -n $output_file && ${#sources[@]} -ne 1 ]]; then
        error '--output requires exactly one selected image'
        return 2
    fi
    if (( ${#sources[@]} > 1 )) && [[ -z $output_dir ]]; then
        error 'multiple selected images require --output-dir'
        return 2
    fi
    if [[ -n $output_file ]]; then
        if [[ -z ${output_file##*/} || ${output_file##*/} != *.* ]]; then
            error "--output requires a filename with an extension: $output_file"
            return 2
        fi
        if has_forbidden_output_extension "$output_file"; then
            error "--output requires a raster image extension: $output_file"
            return 2
        fi
        parent=${output_file%/*}
        [[ $parent != "$output_file" ]] || parent=.
        prepare_output_directory "$parent" 0 1 || return 2
        CURRENT_SOURCE_KEY=${source_keys[0]}
        if ! destination_can_be_used "$output_file" "$overwrite"; then
            error "output destination exists or is unsafe: $output_file"
            return 2
        fi
        reserve_destination "$output_file" || return 2
        case $mode in
            gentle) gentle_destinations[0]=$output_file ;;
            standard) standard_destinations[0]=$output_file ;;
            strong) strong_destinations[0]=$output_file ;;
        esac
    else
        i=0
        while (( i < ${#sources[@]} )); do
            if [[ -n $output_dir ]]; then
                target_directory=$output_dir
            else
                target_directory=${sources[$i]%/*}
                [[ $target_directory != "${sources[$i]}" ]] || target_directory=.
            fi
            plan_source_destinations "$i" "$target_directory" || return 2
            ((i += 1))
        done
    fi

    if [[ -n $output_dir ]]; then
        prepare_output_directory "$output_dir" 0 0 || return 2
    fi

    if (( dry_run )); then
        i=0
        while (( i < ${#sources[@]} )); do
            for destination in "${gentle_destinations[$i]:-}" \
                "${standard_destinations[$i]:-}" "${strong_destinations[$i]:-}"; do
                [[ -n $destination ]] || continue
                if (( overwrite )) && [[ -e $destination ]]; then
                    printf 'would overwrite: %s -> %s\n' "${sources[$i]}" "$destination"
                else
                    printf 'would create: %s -> %s\n' "${sources[$i]}" "$destination"
                fi
            done
            ((i += 1))
        done
        return 0
    fi

    if [[ -n $output_dir ]]; then
        prepare_output_directory "$output_dir" 1 0 || return 2
    fi
    trap cleanup_on_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    i=0
    while (( i < ${#sources[@]} )); do
        process_source "$i" || failures=1
        ((i += 1))
    done
    trap - EXIT HUP INT TERM
    clear_active_temp_directories
    (( failures == 0 ))
}

main "$@"
