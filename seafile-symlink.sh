#!/bin/bash

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
# https://stackoverflow.com/questions/6318809/how-do-i-grab-an-ini-value-within-a-shell-script
function get_config_value {
    awk -F "=" '/'$1'/ {print $2}' "$PRESET" | cut -f1 -d";" | tr -d ' ' | tr -d "'"
}

# Unfortunately, associative arrays are only supported in bash 4+
# Installing it on macOS is a hassle, so we'll stick with bash 3
# https://apple.stackexchange.com/questions/193411/update-bash-to-version-4-0-on-osx
LibraryPath=$(get_config_value 'LibraryPath')
StorageMethod=$(get_config_value 'StorageMethod')
PlaceholderExt=$(get_config_value 'PlaceholderExt')

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
