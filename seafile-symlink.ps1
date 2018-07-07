#Requires -Version 5
# https://github.com/haiwen/seafile/issues/288

# Specify -Preset as a param when calling this script to use custom ini files.
# Ex: `.\seafile-symlink.ps1 -Preset Custom` to use `.\presets\custom.ini`
# Params are capitalization-agnostic so `-preset custom` would work just as well.
param (
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

    $keys = @('LibraryPath', 'StorageMethod', 'PlaceholderExt')

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

    # Modify this via ini if the script isn't in a subfolder of a Seafile library
    $config['LibraryPath'] = Get-AbsolutePath $config['LibraryPath'] $PSScriptRoot

    # Ensure that LibraryPath points to a directory
    Assert-IsDirectory $config['LibraryPath'] 'LibraryPath'

    # Ensure that the specified storage method is valid
    $storageMethods = @('database','placeholder')

    if (!($storageMethods -contains $config['StorageMethod'])) {
        Write-Host 'Invalid StorageMethod:' $config['StorageMethod']
        Write-Host 'Valid methods:' ($storageMethods -join ', ')
        exit 1
    }

    # Extension to use for reading or writing symlink placeholders, with leading period
    $config['PlaceholderExt'] = $config['PlaceholderExt'] -replace '^\.*(.*)$', '.$1'

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


# Helper to find files recursively within a given directory. Returns absolute paths.
# Accepts the same named params as `Get-ChildItem`... except maybe `Path`?
# The cucial difference vs. `Get-ChildItem` is that this doesn't follow symlinks.
# First positional param is the path to the directory within which to search.
function Get-NonsymbolicPaths {
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
            $links += Get-NonsymbolicPaths $subdir.FullName @params
        }

        @($links | Where-Object { $_ })  # Remove empty items
    }
}


# This should detect SymbolicLinks, but not HardLinks or Junctures (intentionally)
# https://stackoverflow.com/questions/817794/find-out-whether-a-file-is-a-symbolic-link-in-powershell
function Get-SymbolicLinkPaths ([string]$DirPath) {
    Get-NonsymbolicPaths $DirPath -Attributes ReparsePoint
}


# Find placeholder files recursively, returning their paths.
function Get-PlaceholderPaths ([string]$DirPath, [string]$PlaceholderExt) {
    Get-NonsymbolicPaths $DirPath -Include "*$PlaceholderExt"
}


function Test-IsDirectory ([string]$Path) {
    (Get-Item -Path $Path) -is [System.IO.DirectoryInfo]
}


function Assert-IsDirectory ([string]$DirPath, [string]$Param) {
    if (!(Test-IsDirectory $DirPath)) {
        $method = (Get-PSCallStack)[1].Command
        Write-Host "$method expects $Param to be a directory."
        exit 1
    }
}


# Helper function for retrieving one path relative to another
function Get-RelativePath ([string]$Path, [string]$DirPath) {
    Assert-IsDirectory $DirPath 'DirPath'
    Push-Location -Path $DirPath
    $out = Resolve-Path -Relative $Path
    Pop-Location
    $out
}


# Helper to normalize a potentially relative path to absolute.
# If $Path is relative, it'll be resolved relative to $DirPath, else returned as-is.
# https://stackoverflow.com/questions/495618/how-to-normalize-a-path-in-powershell
function Get-AbsolutePath ([string]$Path, [string]$DirPath) {
    Assert-IsDirectory $DirPath 'DirPath'
    if (![System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path ($DirPath) $Path
        $Path = [System.IO.Path]::GetFullPath($Path)
    }
    $Path
}


# Generates {link, dest} pairs from placeholder files in library.
function Get-PlaceholderRawData ([string]$LibraryPath, [string]$PlaceholderExt) {
    Get-PlaceholderPaths $LibraryPath $PlaceholderExt | ForEach-Object {
        @{
            # Assumes file w/ single line, no empty trailing ones
            DestPath = Get-Content -Path $_
            LinkPath = $_.TrimEnd($PlaceholderExt)
        }
    }
}


# Generates {link, dest} pairs from database text file in library.
function Get-DatabaseRawData ([string]$LibraryPath) {
    $databasePath = Get-DatabasePath $LibraryPath
    if (Test-Path $databasePath) {
        Get-Content -Path $databasePath | ForEach-Object {
            $line = $_ -Split ' >>> ', 2
            @{
                DestPath = $line[1]
                LinkPath = $line[0]
            }
        }
    } else {
        Write-Host 'No existing database file found for reference'
        @()
    }
}


# Generates {link, dest} pairs from symlinks in library.
function Get-SymbolicLinkRawData ([string]$LibraryPath) {
    Get-SymbolicLinkPaths $LibraryPath | ForEach-Object {
        @{
            DestPath = Get-Item -Path $_ | Select-Object -ExpandProperty Target
            LinkPath = $_
        }
    }
}


# Normalizes all symlink target paths in $Data to absolute.
function Get-AbsoluteData ($Data) {
    $Data | ForEach-Object {
        @{
            DestPath = Get-AbsoluteDestPath $_.LinkPath $_.DestPath
            LinkPath = $_.LinkPath
        }
    }
}


# Helper to de-duplicate records returned by Get-FoobarRawData functions.
# https://stackoverflow.com/questions/14332930/how-to-get-unique-value-from-an-array-of-hashtable-in-powershell
function Get-UniqueData ($HashArray) {
    $HashArray | Select-Object @{
        Expression = { "$($_.Keys):$($_.Values)" }
        Label ="AsString"
    }, @{
        Expression ={$_}
        Label = "Hash"
    } -Unique | Select-Object -ExpandProperty Hash
}


# Runs all Get-FoobarRawData functions, normalizes symlink targets to absolute, and returns de-duped results.
function Get-Data ([string]$LibraryPath, [string]$PlaceholderExt) {
    $data = @()
    $data += Get-PlaceholderRawData $LibraryPath $PlaceholderExt
    $data += Get-DatabaseRawData $LibraryPath
    $data += Get-SymbolicLinkRawData $LibraryPath

    $data = Get-AbsoluteData $data
    $data = Get-UniqueData $data

    $data
}


# Helper to return the directory within which the symlink should be located.
function Get-LinkParentPath ([string]$LinkPath) {
    if (![System.IO.Path]::IsPathRooted($LinkPath)) {
        Write-Host 'Get-LinkParentPath expects LinkPath to be absolute.'
        exit 1
    }
    Split-Path -Path $LinkPath -Parent
}


# Normalize $DestPaths returned by Get-FoobarRawData functions to absolute.
function Get-AbsoluteDestPath ([string]$LinkPath, [string]$DestPath) {
    Get-AbsolutePath $DestPath (Get-LinkParentPath $LinkPath)
}


# Normalize $DestPaths returned by Get-FoobarRawData functions to relative.
function Get-RelativeDestPath ([string]$LinkPath, [string]$DestPath) {
    Get-RelativePath $DestPath (Get-LinkParentPath $LinkPath)
}


# Given a relative or absolute symlink target path, normalize it for how we want to save it.
function Get-NormalizedDestPath ([string]$LinkPath, [string]$DestPath, [string]$LibraryPath) {
    $DestPath = Get-AbsoluteDestPath $LinkPath $DestPath

    # If the path falls below the library root, keep it absolute, else make it relative
    # TODO: Make this a setting? Esp. how to treat paths on the same drive?
    if ($DestPath.StartsWith($LibraryPath)) {
        $DestPath = Get-RelativeDestPath $LinkPath $DestPath
    }

    $DestPath
}


# Expects absolute paths to a symlink, its target, and the Seafile library.
# Returns a `seafile-ignore.txt` line that will cause Seafile to ignore the symlink.
function Get-SymbolicLinkIgnorePath ([string]$LinkPath, [string]$DestPath, [string]$LibraryPath) {
    # Determine the relative path from library root to the symlink for ignoring
    $ignorePath = Get-RelativePath $LinkPath $LibraryPath
    $ignorePath = $ignorePath.TrimStart('.\')
    $ignorePath = $ignorePath.Replace('\','/')

    # If the $DestPath is relative, resolve it as such to the $LinkPath
    $DestPath = Get-AbsoluteDestPath $LinkPath $DestPath

    # If the symlink refers to a directory, treat it as such. The docs are wrong.
    # https://www.seafile.com/en/help/ignore/
    if (Test-IsDirectory $DestPath) {
        $ignorePath = $ignorePath + '/'
    }

    $ignorePath
}


function New-SymbolicLink ([string]$LinkPath, [string]$DestPath, [string]$LibraryPath) {
    # Ensure that the $DestPath fits our business logic
    $DestPath = Get-NormalizedDestPath $LinkPath $DestPath $LibraryPath

    # We need to enter the folder where the symlink will be located for any relative paths to resolve
    Push-Location -Path (Get-LinkParentPath $LinkPath)

    # https://stackoverflow.com/questions/894430/creating-hard-and-soft-links-using-powershell
    New-Item -Path $LinkPath -ItemType SymbolicLink -Value $DestPath -Force | Out-Null

    # Restore our working directory
    Pop-Location

    Write-Host "Created symlink: `"$LinkPath`" >>> `"$DestPath`""
}


# Create a symlink placeholder file.
# TODO: Don't re-create placeholders if they already exist with the same content? Avoid triggering sync.
function New-Placeholder ([string]$LinkPath, [string]$DestPath, [string]$PlaceholderExt) {
    $dir = Get-LinkParentPath $LinkPath
    $name = (Split-Path -Path $LinkPath -Leaf) + $PlaceholderExt
    $file = New-Item -Path $dir -Name $name -Type "file" -Value $DestPath -Force

    Write-Host "Created placeholder: `"$file`" >>> `"$DestPath`""
}


function Remove-Placeholder ([string]$LinkPath, [string]$DestPath, [string]$PlaceholderExt) {
    $dir = Get-LinkParentPath $LinkPath
    $name = (Split-Path -Path $LinkPath -Leaf) + $PlaceholderExt
    $path = "$dir\$name"

    if (Test-Path $path) {
        Remove-Item -Path "$dir\$name"
        Write-Host "Removed placeholder: `"$path`""
    }
}


function Get-DatabasePath ([string]$LibraryPath) {
    $LibraryPath + '\seafile-symlink.txt'
}


# Returns System.IO.FileSystemInfo of seafile-ignore.txt, creating it if necessary
function Get-SeafileIgnoreFile ([string]$LibraryPath) {
    $ignoreFilePath = "$LibraryPath\seafile-ignore.txt"
    if (Test-Path $ignoreFilePath) {
        Write-Host "Found $ignoreFilePath"
        Get-Item -Path $ignoreFilePath
    } else {
        Write-Host "Created $ignoreFilePath"
        New-Item -Path $ignoreFilePath -Type "file"
    }
}


# Used for padding output
function Add-TrailingNewline ([string[]]$Lines) {
    if (($Lines.count -gt 0) -and (![string]::IsNullOrEmpty($Lines[-1]))) {
        $Lines += ''
    }
    $Lines
}


function Write-SeafileIgnoreFile ([string]$LibraryPath, [string[]]$PathsToIgnore ){
    # This is the separator b/w your manually ignored items, and auto-ignored symlinks
    $needle = '### SEAFILE-SYMLINK (AUTOGENERATED) ###'

    # Split the ignore file into two parts based on our needle
    $content = Get-Content (Get-SeafileIgnoreFile $LibraryPath)
    $prefix = $prefix.Where({ $_ -Like $needle }, 'Until')

    # Create the suffix header
    $suffix = @($needle, '# Do not modify the line above or anything below it')

    # Append the ignore paths to our suffix
    $suffix += $PathsToIgnore

    # Ensure that a newline precedes the suffix
    $prefix = Add-TrailingNewline $prefix

    # For comparison's sake, do the same to the source
    $content = Add-TrailingNewline $content

    # Add suffix to prefix with trailing newline
    $contentNew = Add-TrailingNewline ($prefix + $suffix)

    # Check if seafile-ignore.txt was empty of if there were any changes
    # https://stackoverflow.com/questions/9598173/comparing-array-variables-in-powershell
    $hasChanged = !$content -or @(Compare-Object $content $contentNew -SyncWindow 0).Length -gt 0

    # TODO: Avoid adding / remove suffix header if there are no symlinks to ignore
    if ($hasChanged) {
        $output = $contentNew -Join "`n"
        New-Item -Path "$LibraryPath\seafile-ignore.txt" -Type "file" -Value $output -Force | Out-Null
        Write-Host "Updated seafile-ignore.txt"
    } else {
        Write-Host "No changes to seafile-ignore.txt required"
    }
}


# Uses -Preset param from commandline, defaults to `default`
$Config = Get-Config $Preset

# Gather symlink records from placeholders, pseudo-database, and actual symlinks
$Data = Get-Data $Config['LibraryPath'] $Config['PlaceholderExt']

# Create actual symlinks from data
$Data | ForEach-Object { New-SymbolicLink @_ $Config['LibraryPath'] }

# Create placeholders from data
$Data | ForEach-Object { New-Placeholder @_ $Config['PlaceholderExt'] }

# Gather symlink paths to ignore
$IgnorePaths = $Data | ForEach-Object {
    Get-SymbolicLinkIgnorePath @_ $Config['LibraryPath']
}

# Write symlink paths to ignore file
Write-SeafileIgnoreFile $Config['LibraryPath'] $IgnorePaths
