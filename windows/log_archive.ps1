# Windows implementation; the public entry point is log_archive.bat.
param(
    [string]$LogDir,
    [string]$Threshold = '70',
    [string]$BackupDir = '',
    [string]$CapacityMiB = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function HashFile([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $sha.Dispose(); $stream.Dispose() }
}
$work = $null
$lockOwned = $false
function Fail([string]$Message) { throw $Message }
function RegularFiles([string]$Folder) {
    # Explicit recursion skips all reparse points, including junctions.
    foreach ($entry in Get-ChildItem -LiteralPath $Folder -Force) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($entry.PSIsContainer) { RegularFiles $entry.FullName }
        else { $entry }
    }
}
function RunTar([string[]]$TarArgs) {
    & tar.exe @TarArgs
    if ($LASTEXITCODE -ne 0) { Fail "tar failed, exit code $LASTEXITCODE" }
}
try {
    if ($LogDir -eq '--help' -or ($args.Count -eq 1 -and $args[0] -eq '--help')) {
        Write-Output 'Usage: log_archive.bat LOG_DIR [THRESHOLD_PERCENT] [BACKUP_DIR] [CAPACITY_MIB]'
        Write-Output 'Defaults: 70; sibling backup directory; drive capacity. LAB1_MAX_COMPRESSION=1: LZMA.'
        exit 0
    }
    if ($args.Count -gt 0) { Fail 'Too many arguments. Use --help.' }
    if (!$LogDir) { Fail 'LOG_DIR is required. Use --help.' }
    if ($Threshold -notmatch '^(0|[1-9][0-9]?|100)$') { Fail 'Threshold must be 0..100.' }
    $limit = [int]$Threshold
    Get-Command tar.exe -ErrorAction Stop | Out-Null
    $source = Get-Item -LiteralPath $LogDir -Force
    if (!$source.PSIsContainer -or ($source.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Fail 'LOG_DIR must be a regular directory, not a junction or symlink.'
    }
    $log = $source.FullName.TrimEnd('\')
    if ($log -eq [IO.Path]::GetPathRoot($source.FullName).TrimEnd('\')) { Fail 'Drive root is not allowed.' }
    # Reject reparse points in ancestors too, to keep containment checks reliable.
    $ancestor = $source
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail 'Reparse point in source path.' }
        $ancestor = $ancestor.Parent
    }
    if (!$BackupDir) { $BackupDir = Join-Path $source.Parent.FullName 'backup' }
    $backup = [IO.Path]::GetFullPath($BackupDir).TrimEnd('\')
    if ($backup.Equals($log, [StringComparison]::OrdinalIgnoreCase) -or
        $backup.StartsWith($log + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Fail 'BACKUP_DIR must be outside LOG_DIR.'
    }
    $mode = $env:LAB1_MAX_COMPRESSION
    if (!$mode) { $mode = '0' }
    if ($mode -ne '0' -and $mode -ne '1') { Fail 'LAB1_MAX_COMPRESSION must be 0 or 1.' }
    if ($CapacityMiB) {
        if ($CapacityMiB -notmatch '^[1-9][0-9]{0,8}$') { Fail 'CAPACITY_MIB must be 1..999999999.' }
        $capacity = [long]$CapacityMiB * 1MB
    } else {
        $capacity = ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($log))).TotalSize
    }
    if ($capacity -le 0) { Fail 'Capacity must be positive.' }
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $ancestor = Get-Item -LiteralPath $backup -Force
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail 'Reparse point in backup path.' }
        $ancestor = $ancestor.Parent
    }
    $lock = Join-Path $log '.lab1.lock'
    New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
    $lockOwned = $true
    $work = Join-Path $backup ('.lab1-work.' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $files = @(RegularFiles $log | Sort-Object LastWriteTimeUtc, FullName)
    $total = [long]0
    foreach ($file in $files) { $total += $file.Length }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $percent = (100.0 * $total / $capacity).ToString('F2', $culture)
    Write-Output "BEFORE bytes=$total capacity=$capacity usage=$percent% threshold=$limit%"
    if ([decimal]$total * 100 -le [decimal]$capacity * $limit) {
        Write-Output 'OK: threshold is not exceeded; no archive needed.'
        exit 0
    }
    $remaining = $total
    $selected = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        if ([decimal]$remaining * 100 -le [decimal]$capacity * $limit) { break }
        $selected.Add([pscustomobject]@{
            FullName = $file.FullName
            Relative = $file.FullName.Substring($log.Length + 1).Replace('\', '/')
            Length = $file.Length
            Ticks = $file.LastWriteTimeUtc.Ticks
            Hash = (HashFile $file.FullName)
        })
        $remaining -= $file.Length
    }
    Write-Output "SELECTED files=$($selected.Count) bytes=$($total - $remaining)"
    $list = Join-Path $work 'list'
    $members = ($selected | ForEach-Object { './' + $_.Relative + [char]0 }) -join ''
    [IO.File]::WriteAllText($list, $members, [Text.UTF8Encoding]::new($false))
    if ($mode -eq '1') { $suffix = 'tar.lzma'; $codec = '--lzma' }
    else { $suffix = 'tar.gz'; $codec = '-z' }
    $tempArchive = Join-Path $work ('archive.' + $suffix)
    RunTar @('-c', $codec, '-f', $tempArchive, '-C', $log, '--no-recursion', '--null', '-T', $list)
    $extract = Join-Path $work 'verify'
    New-Item -ItemType Directory -Path $extract | Out-Null
    RunTar @('-x', '-f', $tempArchive, '-C', $extract)
    foreach ($file in $selected) {
        $copy = Join-Path $extract $file.Relative
        if ((HashFile $copy) -ne $file.Hash) {
            Fail 'Archive verification failed. Originals were not deleted.'
        }
        $current = Get-Item -LiteralPath $file.FullName -Force
        if ($current.Length -ne $file.Length -or $current.LastWriteTimeUtc.Ticks -ne $file.Ticks -or
            (HashFile $current.FullName) -ne $file.Hash) {
            Fail 'Source changed during archiving. Originals were not deleted.'
        }
    }
    $name = 'archive-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N') + '.' + $suffix
    $archive = Join-Path $backup $name
    Move-Item -LiteralPath $tempArchive -Destination $archive
    Write-Output "ARCHIVE $archive"
    foreach ($file in $selected) {
        $current = Get-Item -LiteralPath $file.FullName -Force
        if ($current.Length -ne $file.Length -or $current.LastWriteTimeUtc.Ticks -ne $file.Ticks) {
            Fail "Source changed before deletion. Archive preserved: $archive"
        }
        Remove-Item -LiteralPath $file.FullName -Force
    }
    $percent = (100.0 * $remaining / $capacity).ToString('F2', $culture)
    Write-Output "AFTER bytes=$remaining usage=$percent%"
    Write-Output 'OK: archive verified; archived originals removed.'
} catch {
    [Console]::Error.WriteLine('ERROR: ' + $_.Exception.Message)
    exit 1
} finally {
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
    if ($lockOwned) { Remove-Item -LiteralPath $lock -Force }
}
