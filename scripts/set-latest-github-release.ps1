[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Repository)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }
Import-Module (Join-Path $PSScriptRoot 'ReleaseAutomation.psm1') -Force

$releaseListJson = & gh release list --repo $Repository --limit 1000 --json tagName,isDraft,isPrerelease
if ($LASTEXITCODE -ne 0) { throw 'Unable to list Releases before selecting Latest.' }
# Assign before array wrapping: Windows PowerShell 5.1 emits a JSON array
# as one pipeline object, which otherwise creates a nested array.
$releaseDocument = ($releaseListJson -join [Environment]::NewLine) | ConvertFrom-Json
$releases = @($releaseDocument)
$highestTag = Select-ContextMiniHighestStableReleaseTag -Releases $releases
if ([string]::IsNullOrWhiteSpace($highestTag)) {
    Write-Host 'No stable SemVer Release is available to mark Latest.'
    exit 0
}
& gh release edit $highestTag --repo $Repository --latest
if ($LASTEXITCODE -ne 0) { throw "Unable to mark $highestTag as Latest." }

# Do not report success merely because the edit command returned zero.
for ($attempt = 0; $attempt -lt 3; $attempt++) {
    $observedOutput = @(& gh api "repos/$Repository/releases/latest" --jq .tag_name)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to verify the Latest release.' }
    $observedTag = ($observedOutput -join '').Trim()
    if ($observedTag -ceq $highestTag) {
        Write-Host "Verified Latest: $highestTag"
        exit 0
    }
    if ($attempt -lt 2) { Start-Sleep -Seconds 1 }
}
throw "Latest verification failed: expected $highestTag, observed $observedTag."
