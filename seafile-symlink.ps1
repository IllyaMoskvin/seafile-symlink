#Requires -Version 5
# https://github.com/haiwen/seafile/issues/288

# Specify -Preset as a param when calling this script to use custom ini files.
# Ex: `.\seafile-symlink.ps1 -Preset Custom` to use `.\presets\custom.ini`
# Params are capitalization-agnostic so `-preset custom` would work just as well.
param(
    [string]
    $Preset='default'
)

# Read INI file into hashtable. Adapted from these examples:
# https://blogs.technet.microsoft.com/heyscriptingguy/2011/08/20/use-powershell-to-work-with-any-ini-file/
# https://serverfault.com/questions/186030/how-to-use-a-config-file-ini-conf-with-a-powershell-script-is-it-possib
# We'll ignore [Sections], comments (;), and require strings to be wrapped in quotes.
function Get-IniContent ([string]$FilePath) {
    $ini = @{}
    switch -regex -file $FilePath
    {
        "(.+?)\s*=(.*)" # Key
        {
            $k,$v = $matches[1..2]
            # Trim trailing comments, if present
            $c = $v.IndexOf(';')
            if ($c -gt 0) {
                $v = $v.Substring(0, $c)
            }
            $v = Invoke-Expression($v)
            $ini[$k] = $v
        }
    }
    $ini
}


# Given a preset name, load and validate its config file.
function Get-Config ([string]$Preset) {
    $config = Get-IniContent ($PSScriptRoot + '\presets\' + $Preset + '.ini')

    $keys = @('LibraryPath', 'PlaceholderExt')

    foreach ($key in $keys) {
        if (!$config[$key]) {
            Write-Host 'Missing key in config:' $key
            exit 1
        }
    }

    if (!(Test-Path $config['LibraryPath'])) {
        Write-Host 'Cannot resolve LibraryPath:' $config['LibraryPath']
        exit 1
    }

    $config
}


# Convert an array into a hastable, with every two array members forming a name-value pair.
# https://stackoverflow.com/questions/27764394/get-valuefromremainingarguments-as-an-hashtable
function Get-ParamHash ([string[]]$ParamArray) {
    $ParamHash = @{}
    for ($i = 0; $i -lt $ParamArray.count; $i+=2) {
        $ParamHash[($ParamArray[$i] -replace '^-+' -replace ':$')] = $ParamArray[$i+1]
    }
    $ParamHash
}


# Helper to find files recursively within a given directory.
# Accepts the same named params as `Get-ChildItem`... except maybe `Path`?
# The cucial difference vs. `Get-ChildItem` is that this doesn't follow symlinks.
# First positional param is the path to the directory within which to search.
function Get-SymbolicPaths {
    param (
        [string]
        $DirPath,

        [parameter(ValueFromRemainingArguments=$true)]
        [string[]]
        $ParamArray
    )
    process {
        # Convert param list to hash
        $params = Get-ParamHash $ParamArray

        # Get symbolic links located directly within this directory
        $links = @(Get-ChildItem -Path "$DirPath\*" @params | ForEach-Object { $_.FullName })

        # Get all subdirectories, excluding symbolic links
        $subdirs = @(Get-ChildItem -Path $DirPath -Attributes Directory+!ReparsePoint)

        # Call this function on each subdirectory and append the result
        foreach ($subdir in $subdirs) {
            $links += Get-SymbolicPaths $subdir.FullName @params
        }

        @($links | Where-Object { $_ })  # Remove empty items
    }
}


# This should detect SymbolicLinks, but not HardLinks or Junctures (intentionally)
# https://stackoverflow.com/questions/817794/find-out-whether-a-file-is-a-symbolic-link-in-powershell
function Get-SymbolicLinks ([string]$DirPath) {
    Get-SymbolicPaths $DirPath -Attributes ReparsePoint
}


# Find placeholder files recursively, returning their paths.
function Get-SymbolicPlaceholders ([string]$DirPath, [string]$PlaceholderExt) {
    Get-SymbolicPaths $DirPath -Include "*.$PlaceholderExt"
}


# Helper function for retrieving one path relative to another
function Get-RelativePath ([string]$PathFrom, [string]$PathTo) {
    Push-Location -Path $PathFrom
    $out = Resolve-Path -Relative $PathTo
    Pop-Location
    $out
}


# Returns System.IO.FileSystemInfo of seafile-ignore.txt, creating it if necessary
function Get-SeafileIgnoreFile ([string]$LibraryPath) {
    if (Test-Path "$LibraryPath\seafile-ignore.txt") {
        Write-Host "Found $LibraryPath\seafile-ignore.txt"
        Get-Item -Path "$LibraryPath\seafile-ignore.txt"
    } else {
        Write-Host "Created $LibraryPath\seafile-ignore.txt"
        New-Item -Path $LibraryPath -Name "seafile-ignore.txt" -Type "file"
    }
}


# Used for padding output
function Add-TrailingNewline ([string[]]$Lines) {
    if (![string]::IsNullOrEmpty($Lines[-1])) {
        $Lines += ''
    }
    $Lines
}


# Uses -Preset param from commandline, defaults to `default`
$Config = Get-Config $Preset

# Modify this via ini if the script isn't in a subfolder of a Seafile library
$LibraryPath = $Config['LibraryPath']

# Extension to use for symlink placeholders
$PlaceholderExt = $Config['PlaceholderExt']

# Look for symlink placeholder files, and create symlinks from them
$phPaths = Get-SymbolicPlaceholders $LibraryPath $PlaceholderExt

foreach ($phPath in $phPaths) {

    $placeholder = Get-Item -Path $phPath

    # Assumes file w/ single line, no empty trailing ones
    $destPath = Get-Content $placeholder
    $linkPath = $phPath.TrimEnd($PlaceholderExt)

    # We need to enter the folder where the symlink will be located for relative paths to resolve
    Push-Location -Path (Split-Path $linkPath -Parent)

    # https://stackoverflow.com/questions/894430/creating-hard-and-soft-links-using-powershell
    $link = New-Item -Path $linkPath -ItemType SymbolicLink -Value $destPath -Force

    # Restore our working directory
    Pop-Location

    Write-Host "Created symlink: `"$linkPath`" >>> `"$destPath`""

}

$linkPaths = Get-SymbolicLinks $LibraryPath
$linkIgnorePaths = @()

foreach ($linkPath in $linkPaths) {

    $link = Get-Item -Path $linkPath

    # Let's work with absolute paths for ease of comparison
    $linkPathAbs = $link.FullName
    $destPathAbs = $link | Select-Object -ExpandProperty Target

    # Get the directory in which the symlink is located
    $linkParentPathAbs = Split-Path $linkPathAbs -Parent

    # Normalize the target path if it's actually relative
    # https://stackoverflow.com/questions/495618/how-to-normalize-a-path-in-powershell
    if (![System.IO.Path]::IsPathRooted($destPathAbs)) {
        $destPathAbs = Join-Path ($linkParentPathAbs) $destPathAbs
        $destPathAbs = [System.IO.Path]::GetFullPath($destPathAbs)
    }

    # Check if the link refers to a directory or a file
    $destIsDir = (Get-Item -Path $destPathAbs) -is [System.IO.DirectoryInfo]

    # Determine the relative path from library root to the symlink for ignoring
    $linkIgnorePath = Get-RelativePath $LibraryPath $linkPathAbs
    $linkIgnorePath = $linkIgnorePath.TrimStart('.\')
    $linkIgnorePath = $linkIgnorePath.Replace('\','/')

    # TODO: Test if symbolic links to folders require forwardslash or absence thereof
    # https://www.seafile.com/en/help/ignore/
    if ($destIsDir) {
        $linkIgnorePath = $linkIgnorePath + '/'
    }

    $linkIgnorePaths += $linkIgnorePath

    # If the path falls below the library root, keep it absolute, else make it relative
    # TODO: Make this a setting? Esp. how to treat paths on the same drive?
    if (!$destPathAbs.StartsWith($LibraryPath)) {
        $destPath = $destPathAbs
    } else {
        $destPath = Get-RelativePath $linkParentPathAbs $destPathAbs
    }

    # Create a symlink placeholder file
    $phName = $link.Name + '.' + $PlaceholderExt
    $phFile = New-Item -Path $linkParentPathAbs -Name $phName -Type "file" -Value $destPath -Force

    Write-Host "Created placeholder: `"$phFile`" >>> `"$destPath`""

}

# This is the separator b/w your manually ignored items, and auto-ignored symlinks
$ignoreNeedle = '### SEAFILE-SYMLINK (AUTOGENERATED) ###'
$ignoreWarning = '# Do not modify the line above or anything below it'

# Split the ignore file into two parts based on our needle
$siContent = Get-Content (Get-SeafileIgnoreFile $LibraryPath)
$siPrefix = $siContent.Where({ $_ -Like $ignoreNeedle }, 'Until')

# Create the suffix header
$siSuffix = @($ignoreNeedle, $ignoreWarning)

# Append the ignore paths to our suffix
$siSuffix += $linkIgnorePaths

# Ensure that a newline precedes the suffix
$siPrefix = Add-TrailingNewline $siPrefix

# For comparison's sake, do the same to the source
$siContent = Add-TrailingNewline $siContent

# Add suffix to prefix with trailing newline
$siContentNew = $siPrefix + $siSuffix + ''

# Check if seafile-ignore.txt was empty of if there were any changes
# https://stackoverflow.com/questions/9598173/comparing-array-variables-in-powershell
$hasChanged = !$siContent -or @(Compare-Object $siContent $siContentNew -SyncWindow 0).Length -gt 0

if ($hasChanged) {
    $output = $siContentNew -Join "`n"
    New-Item -Path "$LibraryPath" -Name "seafile-ignore.txt" -Type "file" -Value $output -Force | Out-Null
    Write-Host "Updated seafile-ignore.txt"
} else {
    Write-Host "No changes to seafile-ignore.txt required"
}
