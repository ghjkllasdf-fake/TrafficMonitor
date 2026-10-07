[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86', 'ARM64EC')][string]$Architecture = 'x64',
    [ValidateSet('Lite', 'Full')][string]$Edition = 'Lite'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$git = if ($env:GIT_EXE) { $env:GIT_EXE } else { 'git' }
$head = & $git rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'A Git checkout is required.' }
if (& $git status --porcelain --untracked-files=normal) { throw 'Packaging requires a clean checkout.' }
$configuration = if ($Edition -eq 'Lite') { 'Release (lite)' } else { 'Release' }
$out = if ($Architecture -eq 'x86') { Join-Path $root "Bin\$configuration" } else { Join-Path $root "Bin\$Architecture\$configuration" }
$proof = Get-Content (Join-Path $out 'fork-build.json') -Raw | ConvertFrom-Json
if ($proof.commit -ne $head -or $proof.version -ne '1.86.1' -or $proof.architecture -ne $Architecture -or $proof.edition -ne $Edition) { throw 'Build provenance mismatch.' }
$exe = Join-Path $out 'TrafficMonitor.exe'
if ((Get-FileHash $exe).Hash -ne $proof.executableSha256) { throw 'Executable changed after build.' }
if ((Get-Item $exe).VersionInfo.FileVersion -ne '1.86.1.0') { throw 'Wrong executable version.' }
$files = [ordered]@{ 'TrafficMonitor.exe' = $exe; 'LICENSE' = (Join-Path $root 'LICENSE'); 'LICENSE_CN' = (Join-Path $root 'LICENSE_CN'); 'FORK-RELEASE.md' = (Join-Path $root 'FORK-RELEASE.md'); 'fork-build.json' = (Join-Path $out 'fork-build.json') }
if ($Edition -eq 'Full') {
    $files['OpenHardwareMonitorApi.dll'] = Join-Path $out 'OpenHardwareMonitorApi.dll'
    $files['LibreHardwareMonitorLib.dll'] = Join-Path $root 'OpenHardwareMonitorApi\LibreHardwareMonitorLib.dll'
}
# Only tracked, named resource types; never recurse an installed application directory.
$resources = & $git -c core.quotepath=false ls-files -- 'TrafficMonitor/language/*' 'TrafficMonitor/skins/*'
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate tracked resources.' }
foreach ($resource in $resources) {
    if ($resource -match '^TrafficMonitor/(language/[^/]+\.ini|skins/[^/]+/(skin\.(ini|xml)|background(_l)?\.(bmp|png)))$') {
        $files[$resource.Substring('TrafficMonitor/'.Length)] = Join-Path $root $resource
    }
}
if (@($files.Keys | Where-Object { $_ -like 'language/*' }).Count -lt 3) { throw 'Missing translations.' }
foreach ($name in $files.Keys) {
    if ($name -match '\.(exe|dll)$') {
        node build/audit.mjs binary $files[$name]
        if ($LASTEXITCODE -ne 0) { throw "Binary audit rejected $name" }
    }
}
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$suffix = if ($Edition -eq 'Lite') { '_Lite' } else { '' }
$zipName = 'TrafficMonitor_V1.86.1_' + $Architecture.ToLowerInvariant() + $suffix + '.zip'
$zipPath = Join-Path $dist $zipName
if (Test-Path $zipPath) { throw 'Output already exists; refusing to overwrite a release.' }
# Stable ordering and timestamps: reproducible ZIP for the same input binaries.
$stamp = [DateTimeOffset]::FromUnixTimeSeconds([long]$proof.sourceDateEpoch)
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in ($files.Keys | Sort-Object)) {
        $entry = $zip.CreateEntry('TrafficMonitor/' + $name, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $stamp
        $input = [IO.File]::OpenRead($files[$name]); $output = $entry.Open()
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
    }
} finally { $zip.Dispose() }
# Re-open the real ZIP: check exact manifest and each member's hash, not only staging intent.
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $expected = @($files.Keys | ForEach-Object { 'TrafficMonitor/' + $_ } | Sort-Object)
    $actual = @($zip.Entries.FullName | Sort-Object)
    if (Compare-Object $expected $actual) { throw 'Archive allowlist mismatch.' }
    foreach ($entry in $zip.Entries) {
        $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') } finally { $sha.Dispose(); $stream.Dispose() }
        if ($hash -ne (Get-FileHash $files[$entry.FullName.Substring('TrafficMonitor/'.Length)]).Hash) { throw 'Archive content mismatch.' }
    }
} finally { $zip.Dispose() }
((Get-FileHash $zipPath).Hash.ToLowerInvariant() + '  ' + $zipName) | Set-Content ($zipPath + '.sha256') -Encoding ASCII
Write-Output "Verified portable ZIP: $zipName ($($files.Count) allowlisted files)."
