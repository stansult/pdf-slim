#!/usr/bin/env bash

set -o nounset

input=''
output=''
cleanup_mode=''
timeout_duration=''
strip_metadata=0

if [[ -n ${FAKE_SCAN_CLEAN_ARGS_FILE:-} ]]; then
    {
        printf '%s\n' BEGIN
        printf '%s\n' "$@"
        printf '%s\n' END
    } >>"$FAKE_SCAN_CLEAN_ARGS_FILE"
fi

while (( $# )); do
    case $1 in
        -i|--input)
            input=${2:-}
            shift 2
            ;;
        -o|--output)
            output=${2:-}
            shift 2
            ;;
        -m|--mode)
            cleanup_mode=${2:-}
            shift 2
            ;;
        --timeout)
            timeout_duration=${2:-}
            shift 2
            ;;
        --strip-metadata)
            strip_metadata=1
            shift
            ;;
        *)
            printf 'fake-scan-clean: unexpected argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

if [[ -z $input || -z $output || -z $cleanup_mode ||
    -z $timeout_duration || $strip_metadata -ne 1 ]]; then
    printf '%s\n' 'fake-scan-clean: incomplete invocation' >&2
    exit 2
fi

case ${FAKE_SCAN_CLEAN_MODE:-success} in
    success)
        cp -- "$input" "$output"
        printf 'created: %s\n' "$output"
        ;;
    failure)
        printf '%s\n' 'fake-scan-clean: deliberate failure' >&2
        exit 9
        ;;
    sleep)
        sleep 5
        ;;
    *)
        printf 'fake-scan-clean: unknown mode: %s\n' \
            "$FAKE_SCAN_CLEAN_MODE" >&2
        exit 2
        ;;
esac
