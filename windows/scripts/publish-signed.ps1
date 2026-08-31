param(
    [Parameter(Mandatory = $true)]
    [string] $CertificateThumbprint,
    [string] $Configuration = "Release",
    [string] $TimestampUrl = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"
$project = Join-Path $PSScriptRoot "..\src\MBPhotos.Receiver.Wpf\MBPhotos.Receiver.Wpf.csproj"
$output = Join-Path $PSScriptRoot "..\artifacts\win-x64"

dotnet publish $project --configuration $Configuration --runtime win-x64 --self-contained true --output $output
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

$exe = Join-Path $output "MBPhotosReceiver.exe"
& signtool.exe sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $exe
if ($LASTEXITCODE -ne 0) { throw "signtool failed" }

& signtool.exe verify /pa /v $exe
if ($LASTEXITCODE -ne 0) { throw "signature verification failed" }

Write-Host "Published and signed: $exe"
