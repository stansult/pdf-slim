#!/usr/bin/env bash

set -o nounset

real_magick=${REAL_MAGICK:?REAL_MAGICK must name the real ImageMagick command}
mode=${FAKE_MAGICK_MODE:-success}

if [[ ${1:-} == identify ]]; then
    exec "$real_magick" "$@"
fi

for argument in "$@"; do
    if [[ $argument == histogram:info:- || $argument == *.icc || \
        $argument == null: ]]; then
        exec "$real_magick" "$@"
    fi
done

# Optional deterministic barrier for publication, source-change, and signal
# tests. Probe and analysis calls return above, so only the cleanup conversion
# waits here.
if [[ -n ${FAKE_MAGICK_READY_FILE:-} ]]; then
    : >"$FAKE_MAGICK_READY_FILE"
fi
if [[ -n ${FAKE_MAGICK_RELEASE_FILE:-} ]]; then
    barrier_attempts=${FAKE_MAGICK_BARRIER_ATTEMPTS:-100}
    if [[ ! $barrier_attempts =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' \
            'fake-magick: FAKE_MAGICK_BARRIER_ATTEMPTS must be a positive integer' >&2
        exit 64
    fi
    barrier_attempt=0
    while [[ ! -e $FAKE_MAGICK_RELEASE_FILE ]]; do
        if (( barrier_attempt >= barrier_attempts )); then
            printf 'fake-magick: timed out waiting for release file: %s\n' \
                "$FAKE_MAGICK_RELEASE_FILE" >&2
            exit 75
        fi
        sleep 0.1
        ((barrier_attempt += 1))
    done
fi

case $mode in
    success)
        exec "$real_magick" "$@"
        ;;
    failure)
        printf '%s\n' 'simulated ImageMagick failure' >&2
        exit 9
        ;;
    partial-failure)
        "$real_magick" "$@"
        printf '%s\n' 'simulated failure after partial output' >&2
        exit 9
        ;;
    sleep)
        sleep 5
        ;;
    *)
        printf 'unknown FAKE_MAGICK_MODE: %s\n' "$mode" >&2
        exit 2
        ;;
esac
