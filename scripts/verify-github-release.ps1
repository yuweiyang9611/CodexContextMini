[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [Parameter(Mandatory=$true)][string]$Tag,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$DownloadDirectory,
    [string]$TrustedDirectory,
    [ValidateSet('true','false')][string]$CompareTested = 'false',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }
Import-Module (Join-Path $PSScriptRoot 'ReleaseAutomation.psm1') -Force

$releaseJson = & gh release view $Tag --repo $Repository --json isDraft,isImmutable,assets
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect published Release $Tag." }
$release = (($releaseJson -join [Environment]::NewLine) | ConvertFrom-Json)
$download = [IO.Path]::GetFullPath($DownloadDirectory)
if (Test-Path -LiteralPath $download) {
    $existing = @(Get-ChildItem -LiteralPath $download -Force)
    if ($existing.Count -gt 0) { throw "Release verification directory is not empty: $download" }
}
else { $null = New-Item -ItemType Directory -Path $download }
& gh release download $Tag --repo $Repository --dir $download
if ($LASTEXITCODE -ne 0) { throw "Unable to download published Release $Tag." }

$compare = $CompareTested -ceq 'true'
$arguments = @{
    Release = $release
    DownloadedDirectory = $download
    Version = $Version
}
if ($compare) {
    $arguments.CompareTested = $true
    $arguments.TrustedDirectory = $TrustedDirectory
}
$verification = Assert-ContextMiniPublishedReleaseAssets @arguments
if ($verification.IsImmutable) {
    foreach ($assetName in $verification.Layout.AssetNames) {
        $verified = $false
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            & gh release verify-asset $Tag $verification.VerificationPaths[$assetName] --repo $Repository
            if ($LASTEXITCODE -eq 0) { $verified = $true; break }
            if ($attempt -lt 5) { Start-Sleep -Seconds 3 }
        }
        if (-not $verified) { throw "GitHub attestation verification failed: $assetName" }
    }
}
else {
    Write-Warning 'Release immutability is disabled; attestation verification was skipped after assets[].digest validation.'
}
if ($Json) { $verification | Select-Object IsImmutable,Layout | ConvertTo-Json -Depth 4 -Compress }
