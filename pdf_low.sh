#!/bin/bash
# 1st parameter − files (by default "*.pdf"); use double quotes with masks
# 2nd parameter − where to write results (by default "new" directory)
# 3rd parameter − what to do ([lowres|bw], by default: lowres)

# if [ $# -eq 0 ]; then
#   echo "No arguments provided"
#   exit 1
# fi

files=$1
if [[ $files == "" || $files == "-" ]] ; then
    files="*.pdf"
fi

dir=$2
if [[ $dir == "" || $dir == "-" ]] ; then
    dir="new"
fi

what=$3
if [[ $what != "bw" ]] ; then
    what="lowres"
fi

for f in $files
do
  if [ -f "$f" ]; then
    if [[ $f == *.pdf ]]; then
      mkdir -p $dir
      echo "Processing $f ..."
      if [[ $what == "bw" ]] ; then
        gs -sDEVICE=pdfwrite -sProcessColorModel=DeviceGray -sColorConversionStrategy=Gray -dCompatibilityLevel=1.4 -dNOPAUSE -dQUIET -dBATCH -sOutputFile="$dir/$f" "$f"
      else
        gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/ebook -dNOPAUSE -dQUIET -dBATCH -sOutputFile="$dir/$f" "$f"
      fi
    fi
  fi
done