#!/bin/bash
#================================================================
# HEADER
#================================================================
#% USAGE
#+    ${SCRIPT_NAME} [preset]
#%
#% SYNOPSIS
#%    Saves symlinks to a syncable format and restores them therefrom.
#%
#% DESCRIPTION
#%    Has the ability to save symlink date via placeholder files, or via
#%    `seafile-symlink.txt` in library root. Create custom ini files in
#%    the `preset` directory. Tell the script which ini file to use via
#%    the `-Preset` param.
#%
#%    Meant to address https://github.com/haiwen/seafile/issues/288
#%
#% OPTIONS
#%    [preset]      Specifies which ini config file to use
#%
#% EXAMPLES
#%    ${SCRIPT_NAME} default             # loads ./presets/default.ini
#%    ${SCRIPT_NAME} default.ini         # loads ./presets/default.ini
#%    ${SCRIPT_NAME} ~/foo/default.ini   # accepts absolute paths
#%
#================================================================
#- IMPLEMENTATION
#-    version         1.0
#-    author          Illya Moskvin <ivmoskvin@gmail.com>
#-    created         2018-07-08
#-    license         MIT
#================================================================
# END_OF_HEADER
#================================================================



#================================================================
# Initialization
#================================================================

# Functions for trapping process and exiting from functions and sub-shells.
# https://stackoverflow.com/questions/9893667/is-there-a-way-to-write-a-bash-function-which-aborts-the-whole-execution-no-mat
# https://stackoverflow.com/questions/24597818/exit-with-error-message-in-bash-oneline
trap "exit 1" TERM
export TOP_PID=$$

function error_exit {
    echo "$1" >&2
    kill -s TERM $TOP_PID
}

# Save the path from which this script was called. We'll restore it later.
DIR_INIT="$(pwd)"

# Change path to where the current script is located
# We will need this for resolving relative paths e.g. within ini files
# https://stackoverflow.com/questions/59895/getting-the-source-directory-of-a-bash-script-from-within
cd "$( dirname "${BASH_SOURCE[0]}" )"



#================================================================
# Function definitions
#================================================================

# Retrieves a value from an ini file.
# Trims trailing comments, spaces, and unwraps single quotes.
function get_config_value {
    # https://stackoverflow.com/questions/6318809/how-do-i-grab-an-ini-value-within-a-shell-script
    v="$(awk -F "=" '/'$1'/ {print $2}' "$PRESET" | cut -f1 -d";" | tr -d ' ' | tr -d "'")"

    if [ -z "$v" ]; then
        error_exit "Missing key in config: $1"
    fi

    echo "$v"
}

# Convert potentially Windows path to Unix
# https://stackoverflow.com/questions/13701218/windows-path-to-posix-path-conversion-in-bash
function get_localized_path {
    path="$(echo "$1" | sed -E 's/^([A-Za-z]):/\\\1/' | sed 's/\\/\//g')"
    if [ "${path:0:1}" != '/' ] && [ "${path:0:1}" != '.' ] ; then
        path="./$path"
    fi
    echo "$path"
}



#================================================================
# Config loading and validation
#================================================================

# Ensure a preset name was passed
if [ $# -ne 1 ]; then
    echo "Usage: $0 [prefixname]"
    exit 1
fi

# Load the preset name from the argument
PRESET=$1

# If preset isn't an absolute path, look for an ini in `presets` subdir
if [[ "$PRESET" != /* ]]; then
   PRESET="${PRESET%.ini}.ini"
   PRESET="presets/$PRESET"
fi

# Unfortunately, associative arrays are only supported in bash 4+
# Installing it on macOS is a hassle, so we'll stick with bash 3
# https://apple.stackexchange.com/questions/193411/update-bash-to-version-4-0-on-osx
LibraryPath="$(get_config_value 'LibraryPath')"
StorageMethod="$(get_config_value 'StorageMethod')"
PlaceholderExt="$(get_config_value 'PlaceholderExt')"

# LibraryPath might be in Windows syntax.
LibraryPath="$(get_localized_path "$LibraryPath")"

# Ensure that LibraryPath exists
if [ ! -d "$LibraryPath" ]; then
    error_exit "Cannot resolve LibraryPath to a directory: $LibraryPath"
fi

# Ensure the storage method is valid
if [ "$StorageMethod" != 'placeholder' ] && [ "$StorageMethod" != 'database' ] ; then
    error_exit "Invalid StorageMethod: $StorageMethod"
fi

# Ensure PlaceholderExt starts with a period
PlaceholderExt=".$(echo "$PlaceholderExt" | sed -e 's/^\.//')"



#================================================================
# Data gathering
#================================================================

# Enter the LibraryPath. We'll be resolving all paths from here onward.
cd "$LibraryPath"

# We'll append data in database format to here, then process it later.
DATA_RAW=()

# Gather data from actual symlinks
# https://stackoverflow.com/questions/22691436/unable-to-add-element-to-array-in-bash
# https://stackoverflow.com/questions/2087001/how-can-i-process-the-results-of-find-in-a-bash-script
while read linkPath; do
    destPath="$(readlink "$linkPath")"
    destPath="$(get_localized_path "$destPath")"
    DATA_RAW+=("$linkPath >>> $destPath")
done < <(find . -type l)

# Gather data from symlink placeholders
while read placeholderPath; do
    linkPath="$(echo "$placeholderPath" | sed -e "s/$PlaceholderExt//")"
    destPath="$(<"$placeholderPath")"
    DATA_RAW+=("$linkPath >>> $destPath")
done < <(find . -name "*$PlaceholderExt")

# Gather data from symlink database
# https://stackoverflow.com/questions/5057083/read-a-file-using-a-bash-script
if [ -f "seafile-symlink.txt" ]; then
    while IFS= read -r datum || [ -n "$datum" ]; do
        if [[ $datum = *' >>> '* ]]; then
            # TODO: Refactor w/ reading in next section
            linkPath="$(awk -F ' >>> ' '{print $1}' <<< "$datum")"
            destPath="$(awk -F ' >>> ' '{print $2}' <<< "$datum")"

            # Normalizes to unix convetion
            linkPath="$(get_localized_path "$linkPath")"
            destPath="$(get_localized_path "$destPath")"

            DATA_RAW+=("$linkPath >>> $destPath")
        fi
    done < "seafile-symlink.txt"
fi

# Ensure the array is unique. Tried a few solutions...
# https://stackoverflow.com/questions/13648410/how-can-i-get-unique-values-from-an-array-in-bash
# https://www.linuxquestions.org/questions/programming-9/bash-combine-arrays-and-delete-duplicates-882286/
OLDIFS="$IFS"
IFS=$'\n'
DATA_RAW=(`for i in "${DATA_RAW[@]}"; do echo "$i" ; done | sort -du`)
IFS="$OLDIFS"

printf '%s\n' "${DATA_RAW[@]}"



#================================================================
# Writing files
#================================================================

# Reset the contents of the symlink database, or delete it if using placeholders
# https://superuser.com/questions/90008/how-to-clear-the-contents-of-a-file-from-the-command-line
if [ "$StorageMethod" == 'database' ] ; then
    > "seafile-symlink.txt"
elif [ -f "seafile-symlink.txt" ] ; then
    rm "seafile-symlink.txt"
fi

# Prepare seafile-ignore.txt for writing
NEEDLE='### SEAFILE-SYMLINK (AUTOGENERATED) ###'
IGNORE=()

if [ -f "seafile-ignore.txt" ] ; then
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == "$NEEDLE" ]]; then
            break
        fi
        IGNORE+=("$line")
    done < "seafile-ignore.txt"
fi

if [[ ${#DATA_RAW[@]} ]]; then
    lastLine="$(printf %s\\n "${IGNORE[@]:(-1)}")"
    if [[ ${#IGNORE[@]} ]] && [[ ${#lastLine} -gt 0 ]]; then
        IGNORE+=('')
    fi
    IGNORE+=("$NEEDLE")
    IGNORE+=('# Do not modify the line above or anything below it')
    printf "%s\n" "${IGNORE[@]}" > "seafile-ignore.txt"
fi

for datum in "${DATA_RAW[@]}"
do
    # Ignore any rogue blank lines
    if [[ $datum != *' >>> '* ]]; then
        continue
    fi

    # https://stackoverflow.com/questions/42662099/how-would-i-delimit-a-string-by-multiple-delimiters-in-bash
    linkPath="$(awk -F ' >>> ' '{print $1}' <<< "$datum")"
    destPath="$(awk -F ' >>> ' '{print $2}' <<< "$datum")"

    # Left-trims ./ to align w/ seafile-ignore.txt examples
    linkPath="$(echo "$linkPath" | sed -e 's/^\.\///')"
    destPath="$(echo "$destPath" | sed -e 's/^\.\///')"

    # Append link path to seafile-ignore.txt
    # Determine if the link will point to a directory
    if [ -d "$(dirname "$linkPath")/$destPath" ] ; then
        echo "$linkPath/" >> "seafile-ignore.txt"
    else
        echo "$linkPath" >> "seafile-ignore.txt"
    fi

    # Make a symlink
    ln -snf "$destPath" "$linkPath"

    # Write a symlink placeholder file
    if [ "$StorageMethod" == 'placeholder' ] ; then
        echo "$destPath" > "$linkPath$PlaceholderExt"
    fi

    # Append to symlink database
    if [ "$StorageMethod" == 'database' ] ; then
        echo "$linkPath >>> $destPath" >> "seafile-symlink.txt"
    fi
done

# Remove placeholder files if they aren't being used
if [ "$StorageMethod" != 'placeholder' ] ; then
    find . -name "*$PlaceholderExt" | xargs rm
fi

# Append trailing newline
if [[ ${#DATA_RAW[@]} ]]; then
    IGNORE+=('')
fi

# Remove seafile-ignore.txt if it would be empty
if [ ${#IGNORE[@]} -eq 0 ]; then
    rm "seafile-ignore.txt"
fi


#================================================================
# Cleanup
#================================================================

# Restore our initial working directory
cd "$DIR_INIT"
