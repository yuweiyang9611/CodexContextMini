[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [Parameter(Mandatory=$true)][string]$Tag,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$SourceSha,
    [Parameter(Mandatory=$true)][string]$GitHubOutput,
    [switch]$RequireCompleteDraft,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }
Import-Module (Join-Path $PSScriptRoot 'ReleaseAutomation.psm1') -Force

$repositoryJson = @(& gh repo view $Repository --json nameWithOwner)
if ($LASTEXITCODE -ne 0) { throw "Unable to access GitHub repository $Repository." }
$repositoryState = (($repositoryJson -join [Environment]::NewLine) | ConvertFrom-Json)
if (-not [string]::Equals([string]$repositoryState.nameWithOwner, $Repository, [StringComparison]::OrdinalIgnoreCase)) {
    throw "GitHub resolved an unexpected repository: $($repositoryState.nameWithOwner)"
}

$tagRef = "refs/tags/$Tag"
$tagRows = @(& git ls-remote --tags origin $tagRef ($tagRef + '^{}'))
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect $Tag." }
$tagCommit = $null
foreach ($row in $tagRows) {
    if ([string]::IsNullOrWhiteSpace([string]$row)) { continue }
    $parts = ([string]$row) -split '\s+', 2
    if ($parts.Count -ne 2) { throw 'Unexpected ls-remote output.' }
    if ($parts[1] -ceq ($tagRef + '^{}')) { $tagCommit = $parts[0] }
    elseif ($null -eq $tagCommit -and $parts[1] -ceq $tagRef) { $tagCommit = $parts[0] }
}

$savedPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $releaseOutput = @(& gh release view $Tag --repo $Repository --json isDraft,isPrerelease,name,tagName,targetCommitish,assets,url 2>&1)
    $releaseExitCode = $LASTEXITCODE
}
finally { $ErrorActionPreference = $savedPreference }
$release = $null
if ($releaseExitCode -eq 0) {
    $release = (($releaseOutput -join [Environment]::NewLine) | ConvertFrom-Json)
}
else {
    $releaseError = ($releaseOutput -join [Environment]::NewLine)
    if ($releaseError -notmatch '(?i)(release not found|HTTP 404)') {
        throw "Unable to inspect GitHub Release ${Tag}: $releaseError"
    }
}
$tagIsAncestor = $false
if (($null -ne $release) -and (-not [bool]$release.isDraft) -and ($null -ne $tagCommit)) {
    & git merge-base --is-ancestor $tagCommit $SourceSha
    if ($LASTEXITCODE -eq 0) { $tagIsAncestor = $true }
    elseif ($LASTEXITCODE -ne 1) { throw 'Unable to compare the published Release tag with the tested commit.' }
}

$stateArguments = @{
    Version = $Version
    Tag = $Tag
    SourceSha = $SourceSha
    TagCommit = $tagCommit
    Release = $release
    TagIsAncestor = $tagIsAncestor
}
if ($RequireCompleteDraft) { $stateArguments.RequireCompleteDraft = $true }
$state = Resolve-ContextMiniReleaseState @stateArguments
Write-ContextMiniGitHubOutput -Path $GitHubOutput -Name 'publish' -Value ($state.Publish.ToString().ToLowerInvariant())
Write-ContextMiniGitHubOutput -Path $GitHubOutput -Name 'recover' -Value ($state.Recover.ToString().ToLowerInvariant())
Write-ContextMiniGitHubOutput -Path $GitHubOutput -Name 'compare_tested' -Value ($state.CompareTested.ToString().ToLowerInvariant())
Write-Host "Release state: $($state.State)"
if ($Json) { $state | ConvertTo-Json -Compress }
