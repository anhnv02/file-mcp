$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

if ($env:OS -ne "Windows_NT") {
    throw "run_windows_dev.ps1 must be run on Windows."
}
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet 8 SDK is required."
}

$ProcessArchitecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$VendorTag = if ($ProcessArchitecture -eq "ARM64") { "windows-arm64" } else { "windows-amd64" }
$TunnelClient = Join-Path $Root "vendor/tunnel-client/$VendorTag/tunnel-client.exe"
if (-not (Test-Path -LiteralPath $TunnelClient -PathType Leaf)) {
    throw "Missing tunnel-client for $VendorTag: $TunnelClient"
}

dotnet build "windows/src/FileMCP.App/FileMCP.App.csproj" -c Debug
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed." }

$Output = Join-Path $Root "windows/src/FileMCP.App/bin/Debug/net8.0-windows"
Copy-Item $TunnelClient (Join-Path $Output "tunnel-client.exe") -Force
Start-Process (Join-Path $Output "FileMCP.exe")
