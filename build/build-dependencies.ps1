[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root 'artifacts\dependencies'
$git = if ($env:GIT_EXE) { $env:GIT_EXE } else { 'git' }
$msbuild = (Get-Command msbuild.exe -ErrorAction Stop).Source
New-Item -ItemType Directory -Force $work | Out-Null
function Get-Source([string]$Name, [string]$Repository, [string]$Commit) {
    $destination = Join-Path $work $Name
    if (Test-Path $destination) { throw "Dependency work directory already exists: $Name" }
    & $git clone --no-checkout "https://github.com/$Repository.git" $destination
    if ($LASTEXITCODE -ne 0) { throw "Cannot clone $Name" }
    & $git -C $destination -c core.autocrlf=false checkout --detach $Commit
    if ($LASTEXITCODE -ne 0 -or (& $git -C $destination rev-parse HEAD) -ne $Commit) { throw "Dependency revision mismatch: $Name" }
    return $destination
}
$hidCommit = '87ad1d383ff29861653eb84d6748073178d690be'
$lhmCommit = 'b8077435b898d57539956388cddf49f7dacb86f7'
$hid = Get-Source 'HidSharp' 'IntergatedCircuits/HidSharp' $hidCommit
$lhm = Get-Source 'LibreHardwareMonitor' 'LibreHardwareMonitor/LibreHardwareMonitor' $lhmCommit
$out = Join-Path $work 'bin'
New-Item -ItemType Directory -Force $out | Out-Null
& $msbuild "$hid\HidSharp\HidSharp.csproj" /t:Rebuild /nologo /p:Configuration=Release /p:TargetFrameworkVersion=v4.7.2 /p:TargetFrameworkProfile= /p:DebugSymbols=false /p:DebugType=None /p:Deterministic=true "/p:PathMap=$work=dependencies" "/p:OutputPath=$out\"
if ($LASTEXITCODE -ne 0) { throw 'HidSharp clean rebuild failed.' }
# Match the shipped 0.9.4 assembly: .NET Framework System.Management 4.0,
# not the newer NuGet implementation. Use the clean rebuilt HidSharp 2.1.0.
$project = Join-Path $lhm 'LibreHardwareMonitorLib\LibreHardwareMonitorLib.csproj'
[xml]$xml = Get-Content $project -Raw
foreach ($package in @($xml.SelectNodes('//PackageReference'))) { [void]$package.ParentNode.RemoveChild($package) }
$references = $xml.CreateElement('ItemGroup')
foreach ($name in @('System.Management', 'HidSharp')) {
    $reference = $xml.CreateElement('Reference'); $reference.SetAttribute('Include', $name)
    if ($name -eq 'HidSharp') {
        $hint = $xml.CreateElement('HintPath'); $hint.InnerText = Join-Path $out 'HidSharp.dll'
        [void]$reference.AppendChild($hint)
    }
    [void]$references.AppendChild($reference)
}
[void]$xml.Project.AppendChild($references)
$xml.Save($project)
& dotnet build $project --configuration Release --framework net472 /p:TargetFrameworks=net472 /p:GeneratePackageOnBuild=false /p:DebugSymbols=false /p:DebugType=None /p:Deterministic=true /p:EnableSourceControlManagerQueries=false /p:EnableSourceLink=false /p:IncludeSourceRevisionInInformationalVersion=false "/p:PathMap=$work=dependencies" --output $out
if ($LASTEXITCODE -ne 0) { throw 'LibreHardwareMonitor clean rebuild failed.' }
node "$PSScriptRoot\audit.mjs" binary "$out\HidSharp.dll" "$out\LibreHardwareMonitorLib.dll"
if ($LASTEXITCODE -ne 0) { throw 'Rebuilt dependencies failed privacy audit.' }
Copy-Item "$hid\License.txt" "$out\HidSharp-LICENSE.txt"
Copy-Item "$lhm\Licenses\License.html" "$out\LibreHardwareMonitor-LICENSE.html"
[ordered]@{ libreHardwareMonitor = $lhmCommit; hidSharp = $hidCommit; framework = 'net472'; debugSymbols = $false } | ConvertTo-Json | Set-Content "$out\dependency-build.json" -Encoding UTF8
