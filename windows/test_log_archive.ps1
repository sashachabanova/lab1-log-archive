Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function HashFile([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $sha.Dispose(); $stream.Dispose() }
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('lab1-tests-' + [guid]::NewGuid().ToString('N'))
$entryPoint = Join-Path $PSScriptRoot 'log_archive.bat'
$oldMode = $env:LAB1_MAX_COMPRESSION
$passed = 0
function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Fixture([string]$Folder) {
    New-Item -ItemType Directory -Path (Join-Path $Folder 'sub dir') -Force | Out-Null
    $names = @('old file.log', 'sub dir/second.log', '-third.log', 'fourth [x] & !.log')
    $result = @()
    # Write actual blocks: no truncate-only or sparse files.
    $block = New-Object byte[] 1MB
    for ($i = 0; $i -lt 4; $i++) {
        $block[0] = [byte]($i + 1)
        $path = Join-Path $Folder $names[$i]
        $stream = [IO.File]::Create($path)
        try { for ($j = 0; $j -lt 128; $j++) { $stream.Write($block, 0, $block.Length) } }
        finally { $stream.Dispose() }
        [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::new(2020, 1, $i + 1, 0, 0, 0, [DateTimeKind]::Utc))
        $result += [pscustomobject]@{ Name = $names[$i]; Hash = (HashFile $path) }
    }
    return $result
}
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $cases = @(
        @{Name='below_threshold'; Threshold=90; Count=0; Mode='0'},
        @{Name='exact_threshold'; Threshold=80; Count=0; Mode='0'},
        @{Name='one_oldest'; Threshold=70; Count=1; Mode='0'},
        @{Name='two_oldest'; Threshold=50; Count=2; Mode='0'},
        @{Name='lzma'; Threshold=70; Count=1; Mode='1'},
        @{Name='zero_threshold'; Threshold=0; Count=4; Mode='0'}
    )
    foreach ($case in $cases) {
        $base = Join-Path $root $case.Name
        $logs = Join-Path $base 'log space'; $backup = Join-Path $base 'backup space'
        $files = @(Fixture $logs)
        $outside = Join-Path $base 'outside'
        New-Item -ItemType Directory -Path $outside | Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'sentinel'), 'outside sentinel')
        $junction = Join-Path $logs 'external-link'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        $bytes = (Get-ChildItem -LiteralPath $logs -File -Recurse | Measure-Object Length -Sum).Sum
        Assert ($bytes -eq 512MB) 'Fixture must contain 512 MiB'
        $env:LAB1_MAX_COMPRESSION = $case.Mode
        Write-Output "`nTEST $($case.Name) (512 MiB)"
        & $entryPoint $logs ([string]$case.Threshold) $backup '640'
        Assert ($LASTEXITCODE -eq 0) 'Main script failed'
        $archives = @(Get-ChildItem -LiteralPath $backup -File -Filter 'archive-*')
        $extract = Join-Path $base 'extracted'
        New-Item -ItemType Directory -Path $extract | Out-Null
        if ($case.Count -eq 0) { Assert ($archives.Count -eq 0) 'Unexpected archive' }
        else {
            Assert ($archives.Count -eq 1) 'Expected exactly one archive'
            $suffix = if ($case.Mode -eq '1') { '.tar.lzma' } else { '.tar.gz' }
            Assert ($archives[0].Name.EndsWith($suffix)) 'Wrong archive extension'
            $magic = [IO.File]::OpenRead($archives[0].FullName)
            try { $first = $magic.ReadByte(); $second = $magic.ReadByte() } finally { $magic.Dispose() }
            if ($case.Mode -eq '1') { Assert ($first -eq 0x5d) 'Not LZMA data' }
            else { Assert ($first -eq 0x1f -and $second -eq 0x8b) 'Not gzip data' }
            & tar.exe -xf $archives[0].FullName -C $extract
            Assert ($LASTEXITCODE -eq 0) 'Archive cannot be extracted'
            Assert (@(Get-ChildItem -LiteralPath $extract -Recurse -File).Count -eq $case.Count) 'Wrong archive member count'
        }
        for ($i = 0; $i -lt 4; $i++) {
            $original = Join-Path $logs $files[$i].Name
            $copy = Join-Path $extract $files[$i].Name
            if ($i -lt $case.Count) {
                Assert (!(Test-Path -LiteralPath $original)) 'Archived source remains'
                Assert ((HashFile $copy) -eq $files[$i].Hash) 'Archived data differs'
            } else {
                Assert (!(Test-Path -LiteralPath $copy)) 'New file unexpectedly archived'
                Assert ((HashFile $original) -eq $files[$i].Hash) 'Remaining data differs'
            }
        }
        $bytes = [long]0
        foreach ($left in Get-ChildItem -LiteralPath $logs -File -Recurse) { $bytes += $left.Length }
        Assert ($bytes -eq (4 - $case.Count) * 128MB) 'Wrong final size'
        Assert (!(Test-Path -LiteralPath (Join-Path $logs '.lab1.lock'))) 'Lock remains'
        Assert ([IO.File]::ReadAllText((Join-Path $outside 'sentinel')) -eq 'outside sentinel') 'Junction target changed'
        # Delete just the junction before recursive fixture cleanup (PS 5.1).
        [IO.Directory]::Delete($junction)
        $passed++; Write-Output "PASS $($case.Name)"
        Remove-Item -LiteralPath $base -Recurse -Force
    }
    $base = Join-Path $root 'invalid'; $logs = Join-Path $base 'log'; $backup = Join-Path $base 'backup'
    $files = @(Fixture $logs)
    foreach ($kind in @('bad_threshold', 'bad_capacity', 'nested_backup', 'invalid_compression', 'locked')) {
        $threshold = '70'; $capacity = '640'; $destination = $backup; $env:LAB1_MAX_COMPRESSION = '0'
        switch ($kind) {
            'bad_threshold' { $threshold = 'abc' }
            'bad_capacity' { $capacity = '0' }
            'nested_backup' { $destination = Join-Path $logs 'backup' }
            'invalid_compression' { $env:LAB1_MAX_COMPRESSION = 'bad' }
            'locked' { New-Item -ItemType Directory -Path (Join-Path $logs '.lab1.lock') | Out-Null }
        }
        # cmd redirection keeps expected errors out of the PowerShell error stream.
        $out = Join-Path $base 'expected-error.txt'
        $command = '""{0}" "{1}" {2} "{3}" {4} > "{5}" 2>&1"' -f $entryPoint, $logs, $threshold, $destination, $capacity, $out
        & cmd.exe /d /s /c $command
        Assert ($LASTEXITCODE -ne 0) "$kind unexpectedly succeeded"
        Assert (([IO.File]::ReadAllText($out)).Contains('ERROR:')) "$kind failed before reaching the script"
        foreach ($file in $files) {
            Assert ((HashFile (Join-Path $logs $file.Name)) -eq $file.Hash) "$kind changed a source"
        }
        if (Test-Path -LiteralPath $backup) {
            Assert (@(Get-ChildItem -LiteralPath $backup -Recurse -File).Count -eq 0) 'Unexpected archive'
        }
        if ($kind -eq 'locked') { Remove-Item -LiteralPath (Join-Path $logs '.lab1.lock') }
        $passed++; Write-Output "PASS $kind (512 MiB preserved)"
    }
    Write-Output "`nRESULT: $passed tests passed."
} catch {
    [Console]::Error.WriteLine('FAIL: ' + $_.Exception.Message)
    exit 1
} finally {
    $env:LAB1_MAX_COMPRESSION = $oldMode
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
