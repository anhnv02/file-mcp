$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

trap {
    $Message = $_.Exception.ToString()
    $Message = $Message.Replace("%", "%25")
    $Message = $Message.Replace("`r", "%0D")
    $Message = $Message.Replace("`n", "%0A")
    Write-Host "::error file=tests/test_windows_app.ps1,title=Windows app smoke failure::$Message"
    exit 1
}

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

if ($env:OS -ne "Windows_NT") {
    throw "Windows app smoke test must run on Windows."
}

$Archive = Join-Path $Root "dist/FileMCP-v0.4.0-windows-x64.zip"
if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) {
    throw "Windows x64 release archive is missing: $Archive"
}

$SmokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("filemcp-windows-app-smoke-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $SmokeRoot | Out-Null
Expand-Archive -LiteralPath $Archive -DestinationPath $SmokeRoot -Force
$Exe = Join-Path $SmokeRoot "FileMCP.exe"
$TunnelClient = Join-Path $SmokeRoot "tunnel-client.exe"
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    throw "FileMCP.exe is missing from the Windows x64 release archive."
}
if (-not (Test-Path -LiteralPath $TunnelClient -PathType Leaf)) {
    throw "tunnel-client.exe is missing from the Windows x64 release archive."
}
$TunnelVersion = & $TunnelClient --version
if ($LASTEXITCODE -ne 0 -or $TunnelVersion -notmatch '^0\.0\.12\+881c9a8fed7cccbe6607cd419863bbca506b8215 ') {
    throw "Unexpected packaged tunnel-client version: $TunnelVersion"
}

$StartedAt = Get-Date
$Process = Start-Process -FilePath $Exe -PassThru
try {
    $Deadline = (Get-Date).AddSeconds(12)
    $WindowReady = $false
    while ((Get-Date) -lt $Deadline) {
        Start-Sleep -Milliseconds 500
        $Process.Refresh()
        if ($Process.HasExited) {
            $EventText = ""
            try {
                $Events = Get-WinEvent -FilterHashtable @{ LogName = "Application"; StartTime = $StartedAt.AddSeconds(-2) } -ErrorAction Stop |
                    Where-Object { $_.ProviderName -in @(".NET Runtime", "Application Error", "Windows Error Reporting") -and $_.Message -match "FileMCP" } |
                    Select-Object -First 8
                if ($Events) {
                    $EventText = ($Events | ForEach-Object { "[$($_.ProviderName)] $($_.Message)" }) -join "`n---`n"
                }
            } catch {
                $EventText = "Could not read Application event log: $($_.Exception.Message)"
            }
            throw "FileMCP.exe exited during WPF startup with exit code $($Process.ExitCode).`n$EventText"
        }
        if ($Process.MainWindowHandle -ne 0 -and $Process.MainWindowTitle -eq "FileMCP") {
            $WindowReady = $true
            break
        }
    }
    if (-not $WindowReady) {
        throw "FileMCP.exe stayed alive but did not create the FileMCP main window within 12 seconds."
    }

    if (-not $Process.CloseMainWindow()) {
        throw "FileMCP.exe main window did not accept a normal close request."
    }
    Start-Sleep -Seconds 2
    $Process.Refresh()
    if ($Process.HasExited) {
        throw "FileMCP.exe exited after closing the main window instead of remaining active in the system tray."
    }

    Write-Host "windows-app-startup: ok"
    Write-Host "windows-close-to-tray: ok"
    Write-Host "windows-packaged-tunnel-client: ok"
}
finally {
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $Process.Id -Timeout 10 -ErrorAction SilentlyContinue
    }
    $Process.Dispose()
    Remove-Item -LiteralPath $SmokeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
