[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Repository)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }
Import-Module (Join-Path $PSScriptRoot 'ReleaseAutomation.psm1') -Force

$releaseListJson = & gh release list --repo $Repository --limit 1000 --json tagName,isDraft,isPrerelease
if ($LASTEXITCODE -ne 0) { throw 'Unable to list Releases before selecting Latest.' }
$releases = @(($releaseListJson -join [Environment]::NewLine) | ConvertFrom-Json)
$highestTag = Select-ContextMiniHighestStableReleaseTag -Releases $releases
if ([string]::IsNullOrWhiteSpace($highestTag)) {
    Write-Host 'No stable SemVer Release is available to mark Latest.'
    exit 0
}
& gh release edit $highestTag --repo $Repository --latest
if ($LASTEXITCODE -ne 0) { throw "Unable to mark $highestTag as Latest." }
