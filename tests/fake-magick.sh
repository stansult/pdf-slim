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
