#!/bin/bash

# Retrieves a value from an ini file.
# Trims trailing comments, spaces, and unwraps single quotes.
# https://stackoverflow.com/questions/6318809/how-do-i-grab-an-ini-value-within-a-shell-script
function get_config_value {
	awk -F "=" '/'$1'/ {print $2}' presets/default.ini | cut -f1 -d";" | tr -d ' ' | tr -d "'"
}

# Unfortunately, associative arrays are only supported in bash 4+
# Installing it on macOS is a hassle, so we'll stick with bash 3
# https://apple.stackexchange.com/questions/193411/update-bash-to-version-4-0-on-osx
LibraryPath=$(get_config_value 'LibraryPath')
StorageMethod=$(get_config_value 'StorageMethod')
PlaceholderExt=$(get_config_value 'PlaceholderExt')

echo $LibraryPath
echo $StorageMethod
echo $PlaceholderExt

exit
