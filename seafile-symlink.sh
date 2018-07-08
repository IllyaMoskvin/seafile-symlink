#!/bin/bash
#
# https://github.com/haiwen/seafile/issues/288

#================================================
# Initialization
#================================================

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



#================================================
# Function definitions
#================================================

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



#================================================
# Config loading and validation
#================================================

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



#================================================
# Data gathering
#================================================

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


printf '%s\n' "${DATA_RAW[@]}"



#================================================
# Writing files
#================================================

# Reset the contents of the symlink database, or delete it if using placeholders
# https://superuser.com/questions/90008/how-to-clear-the-contents-of-a-file-from-the-command-line
if [ "$StorageMethod" == 'database' ] ; then
    > "seafile-symlink.txt"
elif [ -f "seafile-symlink.txt" ] ; then
    rm "seafile-symlink.txt"
fi

for datum in "${DATA_RAW[@]}"
do
    # https://stackoverflow.com/questions/42662099/how-would-i-delimit-a-string-by-multiple-delimiters-in-bash
    linkPath="$(awk -F ' >>> ' '{print $1}' <<< "$datum")"
    destPath="$(awk -F ' >>> ' '{print $2}' <<< "$datum")"

    # Left-trims ./ to align w/ seafile-ignore.txt examples
    linkPath="$(echo "$linkPath" | sed -e 's/^\.\///')"
    destPath="$(echo "$destPath" | sed -e 's/^\.\///')"

    # Make a symlink
    # ln -sf $destPath $linkPath

    # Write a symlink placeholder file
    if [ "$StorageMethod" == 'placeholder' ] ; then
        echo "$destPath" > "$linkPath$PlaceholderExt"
    fi

    # Append to symlink database
    if [ "$StorageMethod" == 'database' ] ; then
        echo "$linkPath >>> $destPath" >> "seafile-symlink.txt"
    fi
done



#================================================
# Cleanup
#================================================

# Restore our initial working directory
cd "$DIR_INIT"
