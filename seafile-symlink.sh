#!/bin/bash

# Functions for trapping process and exiting from functions and sub-shells.
# https://stackoverflow.com/questions/9893667/is-there-a-way-to-write-a-bash-function-which-aborts-the-whole-execution-no-mat
# https://stackoverflow.com/questions/24597818/exit-with-error-message-in-bash-oneline
trap "exit 1" TERM
export TOP_PID=$$

function error_exit {
    echo "$1" >&2
    kill -s TERM $TOP_PID
}

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

# Save the path from which this script was called. We'll restore it later.
DIR_INIT="$(pwd)"

# Change path to where the current script is located
# We will need this for resolving relative paths within ini files
# https://stackoverflow.com/questions/59895/getting-the-source-directory-of-a-bash-script-from-within
cd "$( dirname "${BASH_SOURCE[0]}" )"

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

# Unfortunately, associative arrays are only supported in bash 4+
# Installing it on macOS is a hassle, so we'll stick with bash 3
# https://apple.stackexchange.com/questions/193411/update-bash-to-version-4-0-on-osx
LibraryPath="$(get_config_value 'LibraryPath')"
StorageMethod="$(get_config_value 'StorageMethod')"
PlaceholderExt="$(get_config_value 'PlaceholderExt')"


# Convert potentially Windows path to Unix
# https://stackoverflow.com/questions/13701218/windows-path-to-posix-path-conversion-in-bash
function get_localized_path {
    echo "$1" | sed -E 's/^([A-Za-z]):/\\\1/' | sed 's/\\/\//g'
}

# LibraryPath might be in Windows syntax.
LibraryPath="$(get_localized_path "$LibraryPath")"

echo $LibraryPath
echo $StorageMethod
echo $PlaceholderExt

# Ensure that LibraryPath exists
if [ ! -d "$LibraryPath" ]; then
    echo 'Cannot resolve LibraryPath:' $LibraryPath
    exit 1
fi

# Restore our initial working directory
cd "$DIR_INIT"
