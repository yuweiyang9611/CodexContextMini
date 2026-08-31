[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [Parameter(Mandatory=$true)][string]$BeforeCommit,
    [Parameter(Mandatory=$true)][string]$SourceSha,
    [Parameter(Mandatory=$true)][string]$GitHubOutput,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Join-Path $PSScriptRoot '..' }
$root = [IO.Path]::GetFullPath((Get-Item -LiteralPath $RepositoryRoot -Force).FullName)
Import-Module (Join-Path $PSScriptRoot 'ReleaseAutomation.psm1') -Force

$actualSha = ([string](@(& git -C $root rev-parse HEAD) | Select-Object -Last 1)).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the checked-out commit.' }
if ($actualSha -cne $SourceSha) { throw "Checked out $actualSha instead of $SourceSha." }
$planJson = @(& (Join-Path $PSScriptRoot 'resolve-version-change.ps1') -RepositoryRoot $root -BeforeCommit $BeforeCommit -CurrentCommit $SourceSha -Json)
$plan = (($planJson -join [Environment]::NewLine) | ConvertFrom-Json)
$version = [string]$plan.currentReleaseVersion
$tag = [string]$plan.tag
& git -C $root check-ref-format "refs/tags/$tag"
if ($LASTEXITCODE -ne 0) { throw "Invalid release tag: $tag" }

Write-ContextMiniGitHubOutput -Path $GitHubOutput -Name 'release_version' -Value $version
Write-ContextMiniGitHubOutput -Path $GitHubOutput -Name 'tag' -Value $tag
Write-ContextMiniGitHubOutput -Path $GitHubOutput -Name 'changed' -Value (([bool]$plan.changed).ToString().ToLowerInvariant())
Write-Host ([string]$plan.reason)
if ($Json) { $plan | ConvertTo-Json -Compress }
