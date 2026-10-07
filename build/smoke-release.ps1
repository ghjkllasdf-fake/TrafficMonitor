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
# Use matching bitness for native module enumeration and the mixed-mode CLR DLL.
if ($Architecture -eq 'x86' -and [IntPtr]::Size -eq 8) {
    & "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File $PSCommandPath -Architecture $Architecture -Edition $Edition
    if ($LASTEXITCODE -ne 0) { throw 'x86 smoke test failed.' }
    exit 0
}
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
        if ($modules -notcontains 'OpenHardwareMonitorApi.dll') { throw 'Native Full API was not loaded.' }
        # Hardware is intentionally disabled in the GUI, so its managed libraries
        # are lazy-loaded. Resolve and construct their types separately without
        # opening devices or installing kernel drivers.
        $probe = @'
$ErrorActionPreference = 'Stop'
[void][Reflection.Assembly]::LoadFrom((Join-Path $pwd 'HidSharp.dll'))
$library = [Reflection.Assembly]::LoadFrom((Join-Path $pwd 'LibreHardwareMonitorLib.dll'))
$computer = [Activator]::CreateInstance($library.GetType('LibreHardwareMonitor.Hardware.Computer', $true))
if ($null -eq $computer) { throw 'Cannot construct Full hardware library.' }
$computer.Close()
'@
        Push-Location $app
        try {
            & "$PSHOME\powershell.exe" -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe)))
            if ($LASTEXITCODE -ne 0) { throw 'Managed Full dependency probe failed.' }
        } finally { Pop-Location }
    }
    if (-not $process.CloseMainWindow()) { throw 'Cannot request graceful close.' }
    if (-not $process.WaitForExit(15000)) { throw 'Application did not close gracefully.' }
    # CTrafficMonitorDlg::OnClose delegates to CDialog::OnClose: modal dialog
    # cancellation returns IDCANCEL (2), propagated by this MFC application's exit.
    if ($process.ExitCode -ne 2) { throw "Unexpected modal close result: $($process.ExitCode)" }
    [ordered]@{ architecture = $Architecture; edition = $Edition; zipSha256 = $hash; startupSeconds = 25; windowCreated = $true; responding = $true; gracefulExitCode = $process.ExitCode; loadedModules = $modules; limitations = 'Windows Server CI smoke only; no Windows 11 taskbar/DPI/Explorer or hardware sensor validation.' } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root "dist\$name.smoke.json") -Encoding UTF8
} finally {
    if ($null -ne $process) {
        $process.Refresh()
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
        $process.Dispose()
    }
    Remove-Item $directory -Recurse -Force
}
