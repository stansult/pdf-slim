#!/usr/bin/env bash

set -o nounset

output_file=''
source_file=''
expect_source=0
if [[ -n ${FAKE_GS_ARGS_FILE:-} ]]; then
    printf '%s\n' "$@" >"$FAKE_GS_ARGS_FILE"
fi
for argument in "$@"; do
    if (( expect_source )); then
        source_file=$argument
        expect_source=0
        continue
    fi
    case $argument in
        -sOutputFile=*) output_file=${argument#-sOutputFile=} ;;
        -f) expect_source=1 ;;
    esac
done

if [[ -z $output_file ]]; then
    printf '%s\n' 'fake-gs: missing output path' >&2
    exit 64
fi

case ${FAKE_GS_SOURCE_CHANGE:-none} in
    none) ;;
    metadata-only)
        [[ -n $source_file ]] || {
            printf '%s\n' 'fake-gs: missing source path for metadata change' >&2
            exit 64
        }
        source_mode=$(stat -f '%Lp' -- "$source_file" 2>/dev/null || \
            stat -c '%a' -- "$source_file") || exit 64
        sleep 1.1
        chmod u+x "$source_file" || exit 64
        chmod "$source_mode" "$source_file" || exit 64
        ;;
    content-preserve-stat)
        [[ -n $source_file && -n ${FAKE_GS_MTIME_REFERENCE:-} ]] || {
            printf '%s\n' \
                'fake-gs: source and mtime reference are required for content change' >&2
            exit 64
        }
        sleep 1.1
        printf 'X' | dd of="$source_file" bs=1 count=1 conv=notrunc 2>/dev/null
        touch -r "$FAKE_GS_MTIME_REFERENCE" "$source_file"
        ;;
    *)
        printf 'fake-gs: unknown source change: %s\n' \
            "$FAKE_GS_SOURCE_CHANGE" >&2
        exit 64
        ;;
esac

# Optional deterministic barrier for concurrency tests. Signal readiness only
# after the output path has been parsed, then wait a bounded time for release.
if [[ -n ${FAKE_GS_READY_FILE:-} ]]; then
    : >"$FAKE_GS_READY_FILE"
fi
if [[ -n ${FAKE_GS_RELEASE_FILE:-} ]]; then
    barrier_attempts=${FAKE_GS_BARRIER_ATTEMPTS:-100}
    if [[ ! $barrier_attempts =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' \
            'fake-gs: FAKE_GS_BARRIER_ATTEMPTS must be a positive integer' >&2
        exit 64
    fi

    barrier_attempt=0
    while [[ ! -e $FAKE_GS_RELEASE_FILE ]]; do
        if ((barrier_attempt >= barrier_attempts)); then
            printf 'fake-gs: timed out waiting for release file: %s\n' \
                "$FAKE_GS_RELEASE_FILE" >&2
            exit 75
        fi
        sleep 0.1
        ((barrier_attempt += 1))
    done
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
