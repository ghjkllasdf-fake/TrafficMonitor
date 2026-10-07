[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86')][string]$Architecture,
    [ValidateSet('Lite', 'Full')][string]$Edition
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Deliberately restricted to disposable hosted CI: never interact with an installed
# instance, bypass the application's singleton mutex, or change UAC on a user's PC.
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Run the smoke test only on the disposable CI runner.' }
if (Get-Process TrafficMonitor -ErrorAction SilentlyContinue) { throw 'An existing instance must not be disturbed.' }
$root = Split-Path $PSScriptRoot -Parent
$suffix = if ($Edition -eq 'Lite') { '_Lite' } else { '' }
$name = "TrafficMonitor_V1.86.1_${Architecture}${suffix}.zip"
$zip = Join-Path $root "dist\$name"
$hash = (Get-FileHash $zip).Hash.ToLowerInvariant()
if ((Get-Content ($zip + '.sha256') -Raw).Trim() -ne "$hash  $name") { throw 'ZIP checksum mismatch.' }
$directory = Join-Path $root ('artifacts\smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $directory | Out-Null
$process = $null
try {
    Expand-Archive $zip $directory
    $app = Join-Path $directory 'TrafficMonitor'
    # The test configuration is never packaged. Keep settings local and avoid
    # updates, taskbar injection and kernel hardware access in the CI smoke test.
    "[config]`r`nportable_mode=true`r`n" | Set-Content (Join-Path $app 'global_cfg.ini') -Encoding Unicode
    "[general]`r`ncheck_update_when_start=false`r`nhardware_monitor_item=0`r`n[config]`r`nshow_task_bar_wnd=false`r`nshow_notify_icon=false`r`n[other]`r`nno_multistart_warning=true`r`n" | Set-Content (Join-Path $app 'config.ini') -Encoding Unicode
    $process = Start-Process (Join-Path $app 'TrafficMonitor.exe') -WorkingDirectory $app -PassThru
    Start-Sleep -Seconds 25
    $process.Refresh()
    if ($process.HasExited) { throw "Application exited during smoke test: $($process.ExitCode)" }
    if (-not $process.Responding) { throw 'Application is not responding.' }
    if ($process.MainWindowHandle -eq 0) { throw 'No application window was created.' }
    $modules = @($process.Modules | ForEach-Object { $_.ModuleName })
    if ($Edition -eq 'Full') {
        foreach ($dll in @('OpenHardwareMonitorApi.dll', 'LibreHardwareMonitorLib.dll')) {
            if ($modules -notcontains $dll) { throw "Full dependency was not loaded: $dll" }
        }
    }
    if (-not $process.CloseMainWindow()) { throw 'Cannot request graceful close.' }
    if (-not $process.WaitForExit(15000)) { throw 'Application did not close gracefully.' }
    if ($process.ExitCode -ne 0) { throw "Application returned $($process.ExitCode)" }
    [ordered]@{ architecture = $Architecture; edition = $Edition; zipSha256 = $hash; startupSeconds = 25; windowCreated = $true; responding = $true; gracefulExitCode = $process.ExitCode; loadedModules = $modules; limitations = 'Windows Server CI smoke only; no Windows 11 taskbar/DPI/Explorer or hardware sensor validation.' } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root "dist\$name.smoke.json") -Encoding UTF8
} finally {
    if ($null -ne $process) {
        $process.Refresh()
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
        $process.Dispose()
    }
    Remove-Item $directory -Recurse -Force
}
