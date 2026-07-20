#!/usr/bin/env bash

# Safe interface, traversal, and Ghostscript conversion layer. Publication is
# implemented in a later phase; until then, only --dry-run can complete.

set -o nounset

PROGRAM=${0##*/}
VERSION='0.1.0-dev'
LOG_MAGIC='pdf-slim-log-v1'

usage() {
    cat <<EOF
Usage: $PROGRAM [options] [--] FILE_OR_DIRECTORY ...

Exactly one output mode is required:
  --output-dir DIR   Preserve input-relative paths beneath DIR
  --replace          Replace originals only when safe conversion is smaller

Options:
  --recursive        Descend into supplied directories
  --reprocess        Reprocess files that match the replacement log; all safety
                      checks remain enabled (requires --replace)
  --timeout DURATION Per-file conversion timeout (default: 1h)
  --dry-run          Print planned actions; run no Ghostscript and write nothing
  --quality MODE     Image policy: preserve (default), balanced, or small
  --grayscale        Request explicit grayscale conversion
  --preserve-metadata MODE
                      Preserve none, basic, standard (default), or all metadata
  --help              Show this help and exit
  --version           Show the development version and exit
  --                  End option parsing

PDF extensions are matched case-insensitively. Symlinks are warned about and
skipped. Existing output files and destination collisions are errors. The
default metadata policy preserves permissions plus access and modification
timestamps. The "all" metadata mode is currently macOS-specific.

Exit status: 0 success, 1 one or more conversions failed, 2 invalid/unsafe request.
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
        else
            return 1
        fi
        ((i += 1))
    done
    sources=("${kept_sources[@]}")
    source_keys=("${kept_source_keys[@]}")
    relatives=("${kept_relatives[@]}")
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

convert_pdf() {
    local source=$1
    local candidate=$2
    local timeout_command=$3
    local gs_command=$4
    local timeout_duration=$5
    local grayscale=$6
    local quality=$7
    local output status
    local distiller_params=''
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
    local canonical existing
    local i

    if [[ -L $source ]]; then
        warn "skipping symlink: $source"
        return 0
    fi
    if [[ ! -f $source ]]; then
        warn "skipping non-regular file: $source"
        return 0
    fi
    if ! is_pdf_name "$source"; then
        warn "skipping non-PDF file: $source"
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
    local source relative destination destination_key
    local existing_source
    local i j
    local failures=0

    i=0
    while (( i < ${#sources[@]} )); do
        source=${sources[$i]}
        relative=${relatives[$i]}

        if [[ $mode == output ]]; then
            destination=$output_dir/$relative
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
    ACTIVE_CANDIDATE=''
    ACTIVE_METADATA_REFERENCE=''
    release_log_lock
}

process_source() {
    local source=$1
    local relative=$2
    local destination=$3
    local candidate='' candidate_dir source_before source_after
    local timestamp_reference=''
    local original_size candidate_size

    if [[ $mode == output ]]; then
        ensure_output_parent "$relative" || return 1
        candidate_dir=${destination%/*}
        [[ $candidate_dir != "$destination" ]] || candidate_dir=.
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
    convert_pdf "$source" "$candidate" "$timeout_command" "$gs_command" \
        "$timeout_duration" "$grayscale" "$quality" || {
        clear_active_files
        return 1
    }
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

    if [[ $mode == output && ( -e $destination || -L $destination ) ]]; then
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
    mv "$candidate" "$destination" || {
        error "could not publish converted PDF: $destination"
        clear_active_files
        return 1
    }
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
    local mode=''
    local timeout_duration='1h'
    local quality='preserve'
    local metadata_mode='standard'
    local dry_run=0
    local grayscale=0
    local reprocess=0
    local recursive=0
    local end_options=0
    local arg directory relative
    local parse_failed=0
    local discovery_failed=0
    local -a inputs=()
    local -a sources=()
    local -a source_keys=()
    local -a relatives=()
    local -a destination_keys=()
    local -a destination_sources=()
    local -a destinations=()
    local output_root_key=''
    local log_file script_path
    local timeout_command gs_command
    local failures=0 i
    ACTIVE_CANDIDATE=''
    ACTIVE_METADATA_REFERENCE=''
    ACTIVE_LOG_LOCK=''

    while (( $# )); do
        arg=$1
        shift
        if (( end_options )); then
            inputs[${#inputs[@]}]=$arg
            continue
        fi
        case $arg in
            --output-dir)
                if (( $# == 0 )); then
                    error '--output-dir requires a directory argument'
                    parse_failed=1
                    break
                fi
                output_dir=$1
                shift
                if [[ $mode == replace ]]; then
                    error '--output-dir and --replace are mutually exclusive'
                    parse_failed=1
                fi
                mode=output
                ;;
            --replace)
                if [[ $mode == output ]]; then
                    error '--output-dir and --replace are mutually exclusive'
                    parse_failed=1
                fi
                mode=replace
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
                ;;
            --grayscale) grayscale=1 ;;
            --preserve-metadata)
                if (( $# == 0 )); then
                    error '--preserve-metadata requires a mode argument'
                    parse_failed=1
                    break
                fi
                metadata_mode=$1
                shift
                ;;
            --help) usage; return 0 ;;
            --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; return 0 ;;
            --) end_options=1 ;;
            -*) error "unknown option: $arg"; parse_failed=1 ;;
            *) inputs[${#inputs[@]}]=$arg ;;
        esac
    done

    (( parse_failed == 0 )) || return 2
    if [[ -z $mode ]]; then
        error 'exactly one of --output-dir DIR or --replace is required'
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
    fi
    case $quality in
        preserve|balanced|small) ;;
        *)
            error "unsupported quality mode: $quality"
            return 2
            ;;
    esac
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
        error 'at least one file or directory is required'
        return 2
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
        warn 'no PDF files selected for processing'
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
    trap cleanup_active_candidate EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    i=0
    while (( i < ${#sources[@]} )); do
        process_source "${sources[$i]}" "${relatives[$i]}" \
            "${destinations[$i]}" || {
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
