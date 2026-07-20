#!/usr/bin/env bash

set -o nounset

output_file=''
if [[ -n ${FAKE_GS_ARGS_FILE:-} ]]; then
    printf '%s\n' "$@" >"$FAKE_GS_ARGS_FILE"
fi
for argument in "$@"; do
    case $argument in
        -sOutputFile=*) output_file=${argument#-sOutputFile=} ;;
    esac
done

if [[ -z $output_file ]]; then
    printf '%s\n' 'fake-gs: missing output path' >&2
    exit 64
fi

case ${FAKE_GS_MODE:-success} in
    success)
        printf '%s\n' '%PDF-1.7 fake output' >"$output_file"
        ;;
    failure)
        printf '%s\n' 'fake-gs: deliberate failure' >&2
        exit 9
        ;;
    partial-failure)
        printf '%s\n' 'partial output' >"$output_file"
        printf '%s\n' 'fake-gs: deliberate partial failure' >&2
        exit 10
        ;;
    empty)
        : >"$output_file"
        ;;
    sleep)
        sleep 2
        printf '%s\n' 'late output' >"$output_file"
        ;;
    *)
        printf 'fake-gs: unknown mode: %s\n' "$FAKE_GS_MODE" >&2
        exit 64
        ;;
esac
