[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AssetDirectory,
    [Parameter(Mandatory=$true)][string]$Version,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Import-Module (Join-Path $PSScriptRoot 'ReleaseAutomation.psm1') -Force
$layout = Assert-ContextMiniReleaseAssetDirectory -AssetDirectory $AssetDirectory -Version $Version
if ($Json) { $layout | ConvertTo-Json -Compress }
else { Write-Output "Verified release assets for $Version in $([IO.Path]::GetFullPath($AssetDirectory))" }
