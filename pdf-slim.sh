#!/usr/bin/env bash

# Safe interface and traversal layer. Ghostscript conversion is implemented in
# a later phase; until then, only --dry-run can complete processing.

set -o nounset

PROGRAM=${0##*/}
VERSION='0.1.0-dev'

usage() {
    cat <<EOF
Usage: $PROGRAM [options] [--] FILE_OR_DIRECTORY ...

Exactly one output mode is required:
  --output-dir DIR   Preserve input-relative paths beneath DIR
  --replace          Replace originals only after safe conversion (future phase)

Options:
  --recursive        Descend into supplied directories
  --force,
  --reprocess        Bypass replacement-log checks (requires --replace)
  --timeout DURATION Per-file conversion timeout (default: 1h)
  --dry-run          Print planned actions; run no Ghostscript and write nothing
  --quality MODE     Quality policy; currently only "preserve" is accepted
  --grayscale        Request explicit grayscale conversion
  --help              Show this help and exit
  --version           Show the development version and exit
  --                  End option parsing

PDF extensions are matched case-insensitively. Symlinks are warned about and
skipped. Existing output files and destination collisions are errors. The
current development version requires --dry-run because conversion is not yet
implemented.

Exit status: 0 success, 2 invalid/unsafe request, 3 conversion unavailable.
EOF
}

error() {
    printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
}

warn() {
    printf '%s: warning: %s\n' "$PROGRAM" "$*" >&2
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
            printf 'would convert: %s -> %s\n' "$source" "$destination"
        else
            printf 'would replace if smaller: %s\n' "$source"
        fi
        ((i += 1))
    done

    (( failures == 0 ))
}

main() {
    local output_dir=''
    local mode=''
    local timeout_duration='1h'
    local quality='preserve'
    local dry_run=0
    local grayscale=0
    local force=0
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
    local output_root_key=''

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
            --force|--reprocess) force=1 ;;
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
    if [[ $quality != preserve ]]; then
        error "unsupported quality mode: $quality (currently only preserve is accepted)"
        return 2
    fi
    if [[ -z $timeout_duration ]]; then
        error '--timeout duration must not be empty'
        return 2
    fi
    if (( force )) && [[ $mode != replace ]]; then
        error '--force/--reprocess requires --replace'
        return 2
    fi
    if (( ${#inputs[@]} == 0 )); then
        error 'at least one file or directory is required'
        return 2
    fi

    # Retained for the conversion phase; parsing them now stabilizes the CLI.
    : "$timeout_duration" "$grayscale"

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
        warn 'no PDF files selected'
        return 0
    fi
    plan_actions || return 2

    if (( ! dry_run )); then
        error 'conversion is not implemented yet; use --dry-run to inspect the plan'
        return 3
    fi
    return 0
}

main "$@"
