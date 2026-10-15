#!/usr/bin/env bash

set -o nounset

command_name=${0##*/}
mode=${FAKE_SCAN_INSPECTION_MODE:-valid}

case $command_name in
    pdfinfo)
        case " $* " in
            *' -f '*)
                if [[ $mode != geometry ]]; then
                    printf '%s\n' 'Page 1 size: 612 x 792 pts'
                fi
                ;;
            *' -url '*)
                printf '%s\n' 'Page  Type          URL'
                if [[ $mode == link ]]; then
                    printf '%s\n' '1     URI           https://example.test/'
                fi
                ;;
            *' -dests '*)
                printf '%s\n' 'Page  Destination'
                if [[ $mode == destination ]]; then
                    printf '%s\n' '1     chapter-one'
                fi
                ;;
            *)
                if [[ $mode == bad-pages ]]; then
                    printf '%s\n' 'Pages: unknown'
                else
                    printf '%s\n' 'Pages: 1'
                fi
                if [[ $mode == encrypted ]]; then
                    printf '%s\n' 'Encrypted: yes'
                else
                    printf '%s\n' 'Encrypted: no'
                fi
                if [[ $mode == form ]]; then
                    printf '%s\n' 'Form: AcroForm'
                else
                    printf '%s\n' 'Form: none'
                fi
                if [[ $mode == javascript ]]; then
                    printf '%s\n' 'JavaScript: yes'
                else
                    printf '%s\n' 'JavaScript: no'
                fi
                ;;
        esac
        ;;
    pdftotext)
        if [[ $mode == text ]]; then
            printf '%s\n' 'searchable text'
        fi
        ;;
    pdfdetach)
        if [[ $mode == attachment ]]; then
            printf '%s\n' '1 embedded files' '1: attachment.txt'
        else
            printf '%s\n' '0 embedded files'
        fi
        ;;
    pdfimages)
        printf '%s\n' \
            'page num type width height color comp bpc enc interp object ID x-ppi y-ppi size ratio'
        case $mode in
            image-zero) ;;
            image-mask)
                printf '%s\n' '1 0 mask 100 100 gray 1 1 image no 1 0 300 300 1K 1%'
                ;;
            image-dpi)
                printf '%s\n' '1 0 image 100 100 rgb 3 8 jpeg no 1 0 0 300 1K 1%'
                ;;
            image-two)
                printf '%s\n' \
                    '1 0 image 100 100 rgb 3 8 jpeg no 1 0 300 300 1K 1%' \
                    '1 1 image 100 100 rgb 3 8 jpeg no 2 0 300 300 1K 1%'
                ;;
            smask-valid)
                printf '%s\n' \
                    '1 0 image 100 100 rgb 3 8 image no 1 0 300 300 1K 1%' \
                    '1 1 smask 100 100 gray 1 8 image no 1 0 300 300 1K 1%'
                ;;
            smask-orphan)
                printf '%s\n' \
                    '1 0 smask 100 100 gray 1 8 image no 1 0 300 300 1K 1%'
                ;;
            smask-object)
                printf '%s\n' \
                    '1 0 image 100 100 rgb 3 8 image no 1 0 300 300 1K 1%' \
                    '1 1 smask 100 100 gray 1 8 image no 2 0 300 300 1K 1%'
                ;;
            smask-dimensions)
                printf '%s\n' \
                    '1 0 image 100 100 rgb 3 8 image no 1 0 300 300 1K 1%' \
                    '1 1 smask 99 100 gray 1 8 image no 1 0 300 300 1K 1%'
                ;;
            smask-dpi)
                printf '%s\n' \
                    '1 0 image 100 100 rgb 3 8 image no 1 0 300 300 1K 1%' \
                    '1 1 smask 100 100 gray 1 8 image no 1 0 299 300 1K 1%'
                ;;
            smask-color)
                printf '%s\n' \
                    '1 0 image 100 100 rgb 3 8 image no 1 0 300 300 1K 1%' \
                    '1 1 smask 100 100 rgb 3 8 image no 1 0 300 300 1K 1%'
                ;;
            smask-two)
                printf '%s\n' \
                    '1 0 image 100 100 rgb 3 8 image no 1 0 300 300 1K 1%' \
                    '1 1 smask 100 100 gray 1 8 image no 1 0 300 300 1K 1%' \
                    '1 2 smask 100 100 gray 1 8 image no 1 0 300 300 1K 1%'
                ;;
            *)
                printf '%s\n' '1 0 image 100 100 rgb 3 8 jpeg no 1 0 300 300 1K 1%'
                ;;
        esac
        ;;
    gs)
        output_pattern=''
        for argument in "$@"; do
            case $argument in
                -sOutputFile=*) output_pattern=${argument#-sOutputFile=} ;;
            esac
        done
        [[ -n $output_pattern ]] || exit 64
        output_file=${output_pattern//%04d/0001}
        printf '%s\n' 'fake residual image' >"$output_file"
        ;;
    magick)
        if [[ $mode == residual ]]; then
            printf '%s\n' '0.5'
        else
            printf '%s\n' '1'
        fi
        ;;
    *)
        printf 'fake-scan-inspector: unexpected command name: %s\n' \
            "$command_name" >&2
        exit 64
        ;;
esac
