#Requires -Version 5
<#
.SYNOPSIS
  Saves symlinks to a syncable format and restores them therefrom.
.DESCRIPTION
  Has the ability to save symlink date via placeholder files, or via
  `seafile-symlink.txt` in library root. Create custom ini files in
  the `preset` directory. Tell the script which ini file to use via
  the `-Preset` param.

  Meant to address https://github.com/haiwen/seafile/issues/288
.PARAMETER Preset
  Specifies which config file to use in the `presets` subdirectory.
.OUTPUTS
  None
.NOTES
  Version:        1.0
  Author:         Illya Moskvin <ivmoskvin@gmail.com>
  Creation Date:  2018-07-07
  License:        MIT
.EXAMPLE
  .\seafile-symlink.ps1 -Prefix MyCustomPreset
  This will search for `.\presets\MyCustomPreset.ini` and load its config.
.EXAMPLE
  .\seafile-symlink.ps1 -Prefix C:\foobar\custom.ini
  This will search for `C:\foobar\custom.ini` and load its config.
#>


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

    # Unless an absolute path is provided, look in the `presets` directory
    if (![System.IO.Path]::IsPathRooted($Preset)) {
        if (!$Preset.EndsWith('.ini')) {
            $Preset += '.ini'
        }
        $Preset = $PSScriptRoot + '\presets\' + $Preset
    }

    if (!(Test-Path $Preset)) {
        Write-Host 'Config not found:' $Preset
        exit 1
    }

    $config = Get-IniContent ($Preset)

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

        $DirPathEncoded = $DirPath.replace('[', "``[").replace(']', "``]")

        # Get symbolic links located directly within this directory
        $links = @(Get-ChildItem -Path "$DirPathEncoded\*" @params | ForEach-Object { $_.FullName })

        # Get all subdirectories, excluding symbolic links
        $subdirs = @(Get-ChildItem -LiteralPath $DirPath -Attributes Directory+!ReparsePoint)

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
    (Get-Item -LiteralPath $Path) -is [System.IO.DirectoryInfo]
}


function Assert-IsDirectory ([string]$DirPath, [string]$Param) {
    if (!(Test-IsDirectory $DirPath)) {
        $method = (Get-PSCallStack)[1].Command
        Write-Host "$method expects $Param to be a directory."
        exit 1
    }
}


# Helper function for retrieving one path relative to another
# Calls Resolve-Path but works for files that don't exist.
# https://stackoverflow.com/questions/3038337/powershell-resolve-path-that-might-not-exist
function Get-RelativePath ([string]$Path, [string]$DirPath) {
    Assert-IsDirectory $DirPath 'DirPath'
    Push-Location -LiteralPath $DirPath
    $out = Resolve-Path -LiteralPath $Path -Relative -ErrorAction 'SilentlyContinue' -ErrorVariable '_frperror'
    if (-not($out)) {
        $out = $_frperror[0].TargetObject
    }
    Pop-Location

    $out
}


# Given a potentially Windows-style path, convert it to Unix-style.
# https://stackoverflow.com/questions/34286173/changing-windows-path-to-unix-path
function Get-NormalizedPath ([string]$Path) {
    if ($Path.StartsWith('.\')) {
        $Path = $Path.TrimStart('.\')
    } elseif (-not $Path.StartsWith('..')) {
        $Path = '\' + $Path
    }
    $Path = $Path.Replace('\','/')
    $Path = $Path.Replace(':','')
    $Path
}


# Given a potentially Unix-style path, convert it to Windows-style.
function Get-LocalizedPath ([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:') {
        if ($Path.StartsWith('/')) {
            $Path = $Path.TrimStart('/')
            $Path = $Path -replace '^([A-Za-z])/', '$1:/'
        } elseif (-not $Path.StartsWith('..')) {
            $Path = './' + $Path
        }
    }
    $Path = $Path.Replace('/','\')
    $Path
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
            LinkPath = $_.TrimEnd($PlaceholderExt)
            DestPath = Get-Content -Path $_
        }
    }
}


# Generates {link, dest} pairs from database text file in library.
function Get-DatabaseRawData ([string]$LibraryPath) {
    $databasePath = Get-DatabasePath $LibraryPath
    if (Test-Path $databasePath) {
        Get-Content -Path $databasePath | Where-Object { $_ } | ForEach-Object {
            $line = $_ -Split ' >>> ', 2
            @{
                LinkPath = $LibraryPath + '/' + $line[0]
                DestPath = $line[1]
            }
        }
    } else {
        Write-Host 'No existing database file found for reference'
    }
}


# Generates {link, dest} pairs from symlinks in library.
function Get-SymbolicLinkRawData ([string]$LibraryPath) {
    Get-SymbolicLinkPaths $LibraryPath | ForEach-Object {
        @{
            LinkPath = $_
            DestPath = Get-Item -LiteralPath $_ | Select-Object -ExpandProperty Target
        }
    }
}


# Convert any normalized (Unix) paths in raw data to Windows conventions.
function Get-LocalizedData ($Data) {
    $Data | ForEach-Object {
        @{
            DestPath = Get-LocalizedPath $_.DestPath
            LinkPath = Get-LocalizedPath $_.LinkPath
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
        Label ='AsString'
    }, @{
        Expression ={$_}
        Label = 'Hash'
    } -Unique | Select-Object -ExpandProperty Hash
}


# Runs all Get-FoobarRawData functions, normalizes symlink targets to absolute, and returns de-duped results.
function Get-Data ([string]$LibraryPath, [string]$PlaceholderExt) {
    $data = @()
    $data += Get-SymbolicLinkRawData $LibraryPath
    $data += Get-DatabaseRawData $LibraryPath
    $data += Get-PlaceholderRawData $LibraryPath $PlaceholderExt

    # Skip clean-up steps if there are no symlinks
    if ($data.Count -gt 0) {
        $data = Get-LocalizedData $data
        $data = Get-AbsoluteData $data
        $data = Get-UniqueData $data
    }

    # https://stackoverflow.com/questions/18476634/powershell-doesnt-return-an-empty-array-as-an-array
    return ,$data
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
function Get-BusinessDestPath ([string]$LinkPath, [string]$DestPath, [string]$LibraryPath) {
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
    $ignorePath = Get-NormalizedPath $ignorePath

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
    $DestPath = Get-BusinessDestPath $LinkPath $DestPath $LibraryPath

    # We need to enter the folder where the symlink will be located for any relative paths to resolve
    Push-Location -LiteralPath (Get-LinkParentPath $LinkPath)

    # https://stackoverflow.com/questions/894430/creating-hard-and-soft-links-using-powershell
    New-Item -Path $LinkPath -ItemType SymbolicLink -Value $DestPath -Force | Out-Null

    # Restore our working directory
    Pop-Location

    Write-Host "Created symlink: `"$LinkPath`" >>> `"$DestPath`""
}


# Given a symlink path, get a path to the corresponding placeholder with extension
function Get-PlaceholderPath ([string]$LinkPath, [string]$PlaceholderExt) {
    $dir = Get-LinkParentPath $LinkPath
    $fname = (Split-Path -Path $LinkPath -Leaf) + $PlaceholderExt
    "$dir\$fname"
}


# Create a symlink placeholder file.
function New-Placeholder ([string]$LinkPath, [string]$DestPath, [string]$PlaceholderExt, [string]$LibraryPath) {
    # Ensure $DestPath follows our business logic and Unix conventions
    $DestPath = Get-BusinessDestPath $LinkPath $DestPath $LibraryPath
    $DestPath = Get-NormalizedPath $DestPath

    $placeholderPath = Get-PlaceholderPath $LinkPath $PlaceholderExt
    Write-Host "Creating placeholder: `"$placeholderPath`" >>> `"$DestPath`""
    Write-IfChanged $placeholderPath $DestPath
}


# Expects both $LinkPath and $DestPath for splatting convenience, but only needs the former.
function Remove-Placeholder ([string]$LinkPath, [string]$DestPath, [string]$PlaceholderExt) {
    $placeholderPath = Get-PlaceholderPath $LinkPath $PlaceholderExt
    if (Test-Path -LiteralPath $placeholderPath) {
        Remove-Item -Path $placeholderPath
        Write-Host "Removed placeholder: `"$placeholderPath`""
    }
}


function Get-DatabasePath ([string]$LibraryPath) {
    $LibraryPath + '\seafile-symlink.txt'
}


# Returns System.IO.FileSystemInfo of file at $Path, creating it if necessary
function Get-File ([string]$Path) {
    if (Test-Path $Path) {
        Write-Host 'Found:' $Path
        Get-Item -Path $Path
    } else {
        Write-Host 'Created:' $Path
        New-Item -Path $Path -Type 'file'
    }
}


# Returns System.IO.FileSystemInfo of seafile-ignore.txt, creating it if necessary
function Get-SeafileIgnoreFile ([string]$LibraryPath) {
    Get-File "$LibraryPath\seafile-ignore.txt"
}


# Used for padding output
function Add-TrailingNewline ([string[]]$Lines) {
    if (($Lines.count -gt 0) -and (![string]::IsNullOrEmpty($Lines[-1]))) {
        $Lines += ''
    }
    $Lines
}


# Write to file in $Path only if there are changes in content
function Write-IfChanged ([string]$Path, [string[]]$ContentNew) {

    # Opinionated for our purpose - return early if there's nothing to write
    if ($ContentNew.Length -lt 1) {
        Write-Host 'Nothing to write:' $Path
        return
    }

    # Get the file contents as string to preserve trailing newlines
    if (Test-Path $Path) {
        $ContentOld = Get-Content $Path -Raw
    } else {
        $ContentOld = ''
    }

    if ($ContentOld.Length -eq 0) {
        Write-Host 'Appears empty:' $Path
    }

    # Add trailing newline to our new content
    $ContentNew = Add-TrailingNewline $ContentNew

    # Convert $ContentNew from [string[]] to [string]
    [string]$ContentNew = $ContentNew -Join "`n"

    if ($ContentNew -eq $ContentOld) {
        Write-Host 'No changes required:' $Path
    } else {
        New-Item -Path $Path -Type 'file' -Value $ContentNew -Force | Out-Null
        Write-Host 'Updated:' $Path
    }
}


function Write-SeafileIgnoreFile ([string]$LibraryPath, [string[]]$PathsToIgnore ){
    # This is the separator b/w your manually ignored items, and auto-ignored symlinks
    $needle = '### SEAFILE-SYMLINK (AUTOGENERATED) ###'

    # Split the ignore file into two parts based on our needle
    $ignoreFile = Get-SeafileIgnoreFile $LibraryPath
    $contentOld = Get-Content ($ignoreFile)
    $contentNew = $contentOld.Where({ $_ -Like $needle }, 'Until')

    # Putting this into a conditional will remove suffix header if there are no symlinks
    if ($PathsToIgnore -and $PathsToIgnore.Length -gt 0) {

        # Ensure that a newline precedes the suffix
        $contentNew = Add-TrailingNewline $contentNew

        # Append the suffix header
        $contentNew += @($needle, '# Do not modify the line above or anything below it')

        # Append the ignore paths to our suffix
        $contentNew += $PathsToIgnore

    } elseif ($contentOld.Count -lt 1) {

        Remove-Item -Path $ignoreFile.FullName
        Write-Host 'Removed seafile-ignore.txt because it would be empty'

    }

    Write-IfChanged "$LibraryPath\seafile-ignore.txt" $contentNew
}


function Write-DatabaseFile ($Data, [string]$LibraryPath) {

    # Exit early if there are no symlinks to write
    if ($Data.Count -lt 1) {
        Write-Host 'No symlink data found'
        Remove-DatabaseFile $LibraryPath
        return
    }

    $contentNew = $Data | ForEach-Object {
        # Link paths should be relative to library root, target paths follow our business logic
        $linkPath = Get-RelativePath $_.LinkPath $LibraryPath
        $destPath = Get-BusinessDestPath $_.LinkPath $_.DestPath $LibraryPath

        # Both paths should be stored normalized to Unix conventions
        $linkPath = Get-NormalizedPath ($linkPath)
        $destPath = Get-NormalizedPath ($destPath)

        $linkPath + ' >>> ' + $destPath
    }

    Write-IfChanged (Get-DatabasePath $LibraryPath) $contentNew
}


function Remove-DatabaseFile ([string]$LibraryPath) {
    $databasePath = Get-DatabasePath $LibraryPath
    if (Test-Path $databasePath) {
        Remove-Item -Path $databasePath
        Write-Host 'Removed database:' $databasePath
    }
}


# Uses -Preset param from commandline, defaults to `default`
$Config = Get-Config $Preset

Write-Host 'Processing LibraryPath:' $Config['LibraryPath']

# Gather symlink records from placeholders, pseudo-database, and actual symlinks
$Data = Get-Data $Config['LibraryPath'] $Config['PlaceholderExt']

# For debug, try uncommenting this before it changes data:
# $Data | ForEach-Object { Write-Host @_ }; exit

# Persist symlink data for syncing using specified StorageMethod
Write-Host 'Using StorageMethod:' $Config['StorageMethod']

switch ($config['StorageMethod']) {
    'placeholder' {
        $Data | ForEach-Object { New-Placeholder @_ $Config['PlaceholderExt'] $Config['LibraryPath'] }
        Remove-DatabaseFile $Config['LibraryPath']
    }
    'database' {
        $Data | ForEach-Object { Remove-Placeholder @_ $Config['PlaceholderExt'] }
        Write-DatabaseFile $Data $Config['LibraryPath']
    }
}

# Gather symlink paths to ignore
$IgnorePaths = $Data | ForEach-Object {
    Get-SymbolicLinkIgnorePath @_ $Config['LibraryPath']
}

# Write symlink paths to ignore file
Write-SeafileIgnoreFile $Config['LibraryPath'] $IgnorePaths

# Create actual symlinks from data
$Data | ForEach-Object { New-SymbolicLink @_ $Config['LibraryPath'] }
