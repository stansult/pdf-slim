#!/bin/bash
# parameter: files (by default "./*"); use double quotes with masks
# logic: If new (converted) file takes less place, replace; otherwise delete it

# Absolute path to this script
SCRIPT=$(greadlink -f "$0")
# Absolute path this script is in
SCRIPTPATH=$(dirname "$SCRIPT")
log_file="$SCRIPTPATH/processed_pdfs.log"

# function with the main command (trying to error out in case any bad warning shown)
pdf_convert() {
    # output=$(gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/ebook -dNOPAUSE -dQUIET -dPDFSTOPONWARNING -dBATCH -sOutputFile="$1" "$2")
    mytimeout=1h       # stop trying after timeout (1h = 1 hour)
    # mytimeout=10s      # 10 sec. timeout for debugging
    
    # ebook (low quality)
    # output=$(timeout --foreground --preserve-status $mytimeout gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/ebook -dNOPAUSE -dQUIET -dPDFSTOPONWARNING -dBATCH -sOutputFile="$1" "$2")
    
    # printer (medium quality)
    output=$(timeout --foreground --preserve-status $mytimeout gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/printer -dNOPAUSE -dQUIET -dPDFSTOPONWARNING -dBATCH -sOutputFile="$1" "$2")
    
    if [[ "$?" == 143 ]] ; then
        echo "Conversion timed out ($mytimeout)"
        return 1
    fi
    
    if [ ! -f "$1" ]; then    # if result file doesn’t exist after command completed
        echo "Error: No result file!"
        return 1
    fi

    # if $debug_log ; then
    #     echo "output: $output"    # debug
    #     sleep 3600
    # fi

    # Let’s treat these weird warnings that are not errors, but are still not good, as errors
    # Update: Btw, this doesn’t work… output is empty :(
    # Need to investigate and rework…

    if [[ "$output" == *"fail"* ]] || [[ "$output" == *"Fail"* ]] || [[ "$output" == *"error"* ]]  || [[ "$output" == *"Error"* ]]  || [[ "$output" == *"abort"* ]] ; then
        if $debug_log ; then echo "$output" ; fi
        return 1
    fi
}

# # function with the main command (original)
# pdf_convert() {
#     gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/ebook -dNOPAUSE -dQUIET -dPDFSTOPONWARNING -dBATCH -sOutputFile="$1" "$2"
# }

# pdf processing function
file_process_func() {
    pdf_file="$@"
    new_file="$pdf_file.pdf"    # Name for the new (temporary) file
    # echo    # debug: if other debug echos are on, this one helps to organize output
    echo "Processing '$pdf_file' ..."
    if pdf_convert "$new_file" "$pdf_file"; then      # No error
        # Compare sizes of the new and old files
        size_old=$(wc -c <"$pdf_file")
        size_new=$(wc -c <"$new_file")
        if $debug_log ; then
            echo "Old file: $size_old"    # debug
            echo "New file: $size_new"    # debug
        fi
        
        if [[ "$size_new" -lt "$size_old" ]]; then
            echo "Old file is larger! Replacing…"
            rm -f "$pdf_file"
            mv "$new_file" "$pdf_file"
        else
            echo "New file is larger or the same size. Nevermind, leaving it unchanged"
            rm -f "$new_file"
        fi
    else                                              # Error
        echo "Error during attempted file conversion"
        rm -f "$new_file"
    fi
}

# main function
main_function() {
    files=$@     # all parameters as one, because of spaces in the names
    # if $debug_log ; then echo "Params: $files" ; fi     # debug
    
    if [[ $files == "" || $files == "-" ]] ; then
        files="./*"
    fi
    
    # this is needed to allow for loop process filenames with spaces
    SAVEIFS=$IFS
    IFS=$(echo -en "\n\b")

    for f in $files
    do
        if [ -f "$f" ]; then    # if file exists
            counter_all=$((counter_all+1))      # increment counter_all
            file_path=$(grealpath "$f")
            
            # Check if the file is in the log
            if grep --quiet --line-regexp --fixed-strings "$file_path" "$log_file"; then
                if $debug_log ; then
                    echo "$counter_all. File '$f' has already been processed, skipping..."
                else
                    echo -ne "Total files: $counter_all"'\r'                   # Files counter
                fi
            else
                if [[ "$f" == *.pdf ]]; then    # if the file has pdf extension
                    counter_pdf=$((counter_pdf+1))      # increment counter_pdf
                    echo
                    echo "$counter_pdf ($counter_all). Current file: $f"
                    file_process_func "$f"

                    # add file to the processed log file so that next time it won’t be processed again
                    # no matter if there was error, success or file was larger and deleted, no need to retry
                    
                    # This sometimes happened when I stopped script abruptly
                    tail -c 1 "$log_file" | od -ta | grep -q nl       # check if the last line lacks EOL
                    if [ $? -eq 1 ]; then echo >> "$log_file"; fi     # if yes, add an empty line
                    
                    echo "$file_path" >> "$log_file"                  # add processed file
                else
                    if $debug_log ; then echo "$counter_all. File '$f' is not pdf file" ; fi
                fi
            fi
        else
            if [[ -d "$f" ]]; then    # if it is directory, go in
                if $debug_log ; then
                    echo
                    echo "'$f' is a directory, switching there"
                fi
                new_param="$f/*"        # had to do this way so that directories with spaces were processed correctly
                main_function "$new_param"
            else
                if $debug_log ; then echo "No such file: '$f'" ; fi
            fi
        fi
    done
    IFS=$SAVEIFS    # restoring IFS
}

debug_log=false
# debug_log=true

counter_pdf=0
counter_all=0
main_function "$1"
