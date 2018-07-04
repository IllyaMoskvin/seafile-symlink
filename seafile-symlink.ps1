#Requires -Version 5
# https://github.com/haiwen/seafile/issues/288

# Modify this if the script isn't in the root of a Seafile library
$rootPath = $PSScriptRoot

# Extension to use for symlink placeholders
$symExt = 'seaflnk'

# This is the separator b/w your ignored files, and auto-ignored symlinks
$ignoreNeedle = '### SEAFILE-SYMLINK (AUTOGENERATED) ###'
$ignoreWarning = '# Do not modify the line above or anything below it'

# Helper function for retrieving one path relative to another
Function GetRelativePath([string]$pathFrom, [string]$pathTo) {
   Push-Location -Path $pathFrom
   $out = Resolve-Path -Relative $pathTo
   Pop-Location
   return $out
}

# Returns System.IO.FileSystemInfo of seafile-ignore.txt, creating it if necessary
Function GetSeafileIgnoreFile {
    if (!(Test-Path "$rootPath\seafile-ignore.txt")) {
        Write-Host "Created $rootPath\seafile-ignore.txt"
        New-Item -Path "$rootPath" -Name "seafile-ignore.txt" -Type "file"
    } else {
        Write-Host "Found $rootPath\seafile-ignore.txt"
        Get-Item -Path "$rootPath\seafile-ignore.txt"
    }
}

# This should detect SymbolicLinks, but not HardLinks or Junctures (intentionally)
# https://stackoverflow.com/questions/817794/find-out-whether-a-file-is-a-symbolic-link-in-powershell
Function GetSymbolicLinks([string]$dir) {

    # Get symbolic links located directly within this directory
    $links = Get-ChildItem -Path $dir -Attributes ReparsePoint | % { $_.FullName }

    # Get all subdirectories, excluding symbolic links
    $subdirs = Get-ChildItem -Path $dir -Attributes Directory+!ReparsePoint | % { $_.FullName }

    # Call this function on each subdirectory and append the result
    foreach( $subdir in $subdirs ) {
        $links += GetSymbolicLinks $subdir
    }

    return $links | ? {$_} # Remove empty items
}

Function GetSymbolicPlaceholders([string]$dir) {

    # Get placeholders located directly within this directory
    $placeholders = Get-ChildItem -Path "$dir\*.$symExt" | % { $_.FullName }

    # Get all subdirectories, excluding symbolic links
    $subdirs = Get-ChildItem -Path $dir -Attributes Directory+!ReparsePoint | % { $_.FullName }

    # Call this function on each subdirectory and append the result
    foreach( $subdir in $subdirs ) {
        $placeholders += GetSymbolicPlaceholders $subdir
    }

    return $placeholders | ? {$_} # Remove empty items
}

# Split the ignore file into two parts based on our needle
$siFile = GetSeafileIgnoreFile
$siContent = Get-Content $siFile
$siPrefix = $siContent.Where({ $_ -Like $ignoreNeedle },'Until')

# Create the suffix header
$siSuffix = @( $ignoreNeedle, $ignoreWarning )

# Ensure that a newline precedes the suffix
if( ![string]::IsNullOrEmpty($siPrefix[-1]) ) {
    $siPrefix += ''
}

# For comparison's sake, do the same to the source
if( ![string]::IsNullOrEmpty($siContent[-1]) ) {
    $siContent += ''
}

# Look for symlink placeholder files, and create symlinks from them
$phPaths = GetSymbolicPlaceholders $rootPath

foreach( $phPath in $phPaths ) {

    $placeholder = Get-Item -Path $phPath

    $content = Get-Content $placeholder
    $destPath = $content[0]

    $linkPath = $phPath.TrimEnd( $symExt )

    # We need to enter the folder where the symlink will be located for relative paths to resolve
    Push-Location -Path ( Split-Path $linkPath -Parent )

    # https://stackoverflow.com/questions/894430/creating-hard-and-soft-links-using-powershell
    $link = New-Item -Path $linkPath -ItemType SymbolicLink -Value $destPath -Force

    # Restore our working directory
    Pop-Location

    Write-Host "Created symlink: `"$linkPath`" >>> `"$destPath`""

}

$linkPaths = GetSymbolicLinks $rootPath

foreach ($linkPath in $linkPaths) {

    $link = Get-Item -Path $linkPath

    # Let's work with absolute paths for ease of comparison
    $linkPathAbs = $link.FullName
    $destPathAbs = $link | Select-Object -ExpandProperty Target

    # Get the directory in which the symlink is located
    $linkParentPathAbs = Split-Path $linkPathAbs -Parent

    # Normalize the target path if it's actually relative
    # https://stackoverflow.com/questions/495618/how-to-normalize-a-path-in-powershell
    if( ![System.IO.Path]::IsPathRooted($destPathAbs) ) {
        $destPathAbs = Join-Path ( $linkParentPathAbs ) $destPathAbs
        $destPathAbs = [System.IO.Path]::GetFullPath($destPathAbs)
    }

    # Check if the link refers to a directory or a file
    $destIsDir = (Get-Item -Path $destPathAbs) -is [System.IO.DirectoryInfo]

    # Determine the relative path from library root to the symlink for ignoring
    $linkIgnorePath = GetRelativePath $rootPath $linkPathAbs
    $linkIgnorePath = $linkIgnorePath.TrimStart('.\')
    $linkIgnorePath = $linkIgnorePath.Replace('\','/')

    # TODO: Test if symbolic links to folders require forwardslash or absence thereof
    # https://www.seafile.com/en/help/ignore/
    If ($destIsDir) { $linkIgnorePath = $linkIgnorePath + '/' }

    $siSuffix += $linkIgnorePath

    # If the path falls below the library root, keep it absolute, else make it relative
    if( !$destPathAbs.StartsWith($rootPath) ) {
        $destPath = $destPathAbs
    } else {
        $destPath = GetRelativePath $linkParentPathAbs $destPathAbs
    }

    # Create a symlink placeholder file
    $phName = $link.Name + '.' + $symExt
    $phFile = New-Item -Path $linkParentPathAbs -Name $phName -Type "file" -Value $destPath -Force

    Write-Host "Created placeholder: `"$phFile`" >>> `"$destPath`""

}

# Add suffix to prefix with trailing newline
$siContentNew = $siPrefix + $siSuffix + ''

# Check if seafile-ignore.txt was empty of if there were any changes
# https://stackoverflow.com/questions/9598173/comparing-array-variables-in-powershell
$hasChanged = !$siContent -or @(Compare-Object $siContent $siContentNew -SyncWindow 0).Length -gt 0

If( $hasChanged ) {
    $output = $siContentNew -Join "`n"
    $siFile = New-Item -Path "$rootPath" -Name "seafile-ignore.txt" -Type "file" -Value $output -Force
    Write-Host "Updated seafile-ignore.txt"
} else {
    Write-Host "No changes to seafile-ignore.txt required"
}
