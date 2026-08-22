param(
    [ValidateSet("x64", "arm64")]
    [string]$Architecture = "x64"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet 8 SDK is required to build the Windows app."
}

$Rid = if ($Architecture -eq "arm64") { "win-arm64" } else { "win-x64" }
$VendorTag = if ($Architecture -eq "arm64") { "windows-arm64" } else { "windows-amd64" }
$TunnelClient = Join-Path $Root "vendor/tunnel-client/$VendorTag/tunnel-client.exe"
$ThirdParty = Join-Path $Root "vendor/tunnel-client/$VendorTag/THIRD-PARTY-LICENSES.txt"
$PublishDir = Join-Path $Root "dist/windows-$Architecture/FileMCP"
$ZipPath = Join-Path $Root "dist/FileMCP-v0.4.0-windows-$Architecture.zip"

foreach ($Required in @(
    $TunnelClient,
    (Join-Path $Root "LICENSE"),
    (Join-Path $Root "vendor/tunnel-client/LICENSE"),
    (Join-Path $Root "vendor/tunnel-client/NOTICE"),
    $ThirdParty
)) {
    if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) {
        throw "Missing required release file: $Required"
    }
}

Remove-Item -Recurse -Force $PublishDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $PublishDir | Out-Null

dotnet publish "windows/src/FileMCP.App/FileMCP.App.csproj" `
    -c Release `
    -r $Rid `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -o $PublishDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }

Copy-Item $TunnelClient (Join-Path $PublishDir "tunnel-client.exe")
Copy-Item (Join-Path $Root "LICENSE") (Join-Path $PublishDir "FileMCP-LICENSE.txt")
Copy-Item (Join-Path $Root "vendor/tunnel-client/LICENSE") (Join-Path $PublishDir "tunnel-client-LICENSE.txt")
Copy-Item (Join-Path $Root "vendor/tunnel-client/NOTICE") (Join-Path $PublishDir "tunnel-client-NOTICE.txt")
Copy-Item $ThirdParty (Join-Path $PublishDir "tunnel-client-THIRD-PARTY-LICENSES.txt")

Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $PublishDir "*") -DestinationPath $ZipPath -CompressionLevel Optimal

Write-Host "Built: $PublishDir"
Write-Host "Archive: $ZipPath"
Get-FileHash -Algorithm SHA256 $ZipPath
