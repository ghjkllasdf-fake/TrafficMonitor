[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86', 'ARM64EC')][string]$Architecture = 'x64',
    [ValidateSet('Lite', 'Full')][string]$Edition = 'Lite'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$git = if ($env:GIT_EXE) { $env:GIT_EXE } else { 'git' }
$head = & $git rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'A Git checkout is required.' }
$dirty = & $git status --porcelain --untracked-files=normal
if ($dirty) { throw 'Build requires a clean committed checkout.' }
node build/audit.mjs source
if ($LASTEXITCODE -ne 0) { throw 'Source audit failed.' }
$msbuild = Get-Command msbuild.exe -ErrorAction SilentlyContinue
if (-not $msbuild) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $found = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
        if ($found) { $msbuild = Get-Command $found }
    }
}
if (-not $msbuild) { throw 'MSVC v143 + MFC + Windows SDK not found. Use the fork release workflow; no global installation is performed.' }
if ($Edition -eq 'Full') {
    if ($Architecture -eq 'ARM64EC') { throw 'Full edition requires x64 or x86 C++/CLI; ARM64EC is Lite only.' }
    & "$PSScriptRoot\build-dependencies.ps1"
    if ($LASTEXITCODE -ne 0) { throw 'Dependency rebuild failed.' }
}
$epoch = & $git show -s --format=%ct HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot determine commit time.' }
$date = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).UtcDateTime.ToString('yyyy-MM-dd')
$configuration = if ($Edition -eq 'Lite') { 'Release (lite)' } else { 'Release' }
$solution = if ($Edition -eq 'Lite') { 'TrafficMonitor_Lite.sln' } else { 'TrafficMonitor.sln' }
$buildDir = Join-Path $root 'artifacts'
New-Item -ItemType Directory -Force (Join-Path $buildDir 'temp'), (Join-Path $buildDir 'empty-user-props') | Out-Null
# Temporary compiler files and per-user property imports stay inside the checkout.
$oldTemp = $env:TEMP; $oldTmp = $env:TMP
try {
    $env:TEMP = Join-Path $buildDir 'temp'; $env:TMP = $env:TEMP
    & $msbuild.Source $solution /t:Rebuild /m /nologo "/p:Configuration=$configuration" "/p:Platform=$Architecture" /p:PlatformToolset=v143 /p:UseOfMfc=Static "/p:ForceImportBeforeCppTargets=$PSScriptRoot\ForkRelease.targets" "/p:UserRootDir=$buildDir\empty-user-props\" "/p:ForkBuildDate=$date"
    if ($LASTEXITCODE -ne 0) { throw 'MSBuild failed; no package was produced.' }
    $out = if ($Architecture -eq 'x86') { Join-Path $root "Bin\$configuration" } else { Join-Path $root "Bin\$Architecture\$configuration" }
    $exe = Join-Path $out 'TrafficMonitor.exe'
    node build/normalize-vendor-paths.mjs $exe
    if ($LASTEXITCODE -ne 0) { throw 'Vendor diagnostic path normalization failed.' }
    node build/audit.mjs binary $exe
    if ($LASTEXITCODE -ne 0) { throw 'Built executable failed binary audit.' }
    $version = (Get-Item $exe).VersionInfo
    if ($version.FileVersion -ne '1.86.1.0' -or $version.ProductVersion -ne '1.86.1.0') { throw 'PE version mismatch.' }
    $provenance = [ordered]@{ commit = $head; architecture = $Architecture; edition = $Edition; version = '1.86.1'; executableSha256 = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant(); sourceDateEpoch = [long]$epoch }
    $provenance | ConvertTo-Json | Set-Content (Join-Path $out 'fork-build.json') -Encoding UTF8
    & "$PSScriptRoot\package-release.ps1" -Architecture $Architecture -Edition $Edition
} finally {
    $env:TEMP = $oldTemp; $env:TMP = $oldTmp
}
