$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

if ($env:OS -ne "Windows_NT") {
    throw "Windows integration tests must run on Windows."
}
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet 8 SDK is required."
}


$TunnelClient = Join-Path $Root "vendor/tunnel-client/windows-amd64/tunnel-client.exe"
if (-not (Test-Path -LiteralPath $TunnelClient -PathType Leaf)) {
    throw "Missing vendored Windows tunnel-client: $TunnelClient"
}

$ProfileRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("filemcp-windows-tunnel-profile-" + [Guid]::NewGuid().ToString("N"))
$ProfileName = "local-auth-profile"
$ProfilePath = Join-Path $ProfileRoot ($ProfileName + ".yaml")
$LocalAuthToken = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
$SavedEnvironment = @{}
foreach ($Name in @("FILEMCP_LOCAL_AUTH_TOKEN", "MCP_EXTRA_HEADERS", "MCP_DISCOVERY_EXTRA_HEADERS")) {
    $SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, "Process")
}
try {
    New-Item -ItemType Directory -Force $ProfileRoot | Out-Null
    $env:FILEMCP_LOCAL_AUTH_TOKEN = $LocalAuthToken
    $env:MCP_EXTRA_HEADERS = "X-FileMCP-Local-Token: env:FILEMCP_LOCAL_AUTH_TOKEN"
    $env:MCP_DISCOVERY_EXTRA_HEADERS = "X-FileMCP-Local-Token: env:FILEMCP_LOCAL_AUTH_TOKEN"

    & $TunnelClient init `
        --sample sample_mcp_remote_no_auth `
        --profile $ProfileName `
        --profile-dir $ProfileRoot `
        --force `
        --tunnel-id tunnel_0123456789abcdef0123456789abcdef `
        --mcp-server-url http://127.0.0.1:18088/mcp `
        --health-listen-addr 127.0.0.1:0 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Vendored tunnel-client init failed with exit code $LASTEXITCODE." }
    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) { throw "Vendored tunnel-client did not create the expected profile." }

    $ProfileText = Get-Content -LiteralPath $ProfilePath -Raw
    if ($ProfileText.Contains($LocalAuthToken) -or
        $ProfileText -match "(?i)extra_headers|X-FileMCP-Local-Token|FILEMCP_LOCAL_AUTH_TOKEN") {
        throw "Vendored tunnel-client persisted the per-runtime local auth credential or header configuration."
    }
    Write-Host "windows-tunnel-client-local-auth-env: ok"
}
finally {
    foreach ($Name in $SavedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($Name, $SavedEnvironment[$Name], "Process")
    }
    Remove-Item -LiteralPath $ProfileRoot -Recurse -Force -ErrorAction SilentlyContinue
}

dotnet run --project "windows/tests/FileMCP.Core.Tests/FileMCP.Core.Tests.csproj" -c Release
if ($LASTEXITCODE -ne 0) { throw "Windows integration tests failed." }
