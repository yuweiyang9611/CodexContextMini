[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Create','Recover')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$Repository,
    [Parameter(Mandatory=$true)][string]$Tag,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$SourceSha,
    [Parameter(Mandatory=$true)][string]$AssetDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }
Import-Module (Join-Path $PSScriptRoot 'ReleaseAutomation.psm1') -Force
$layout = Assert-ContextMiniReleaseAssetDirectory -AssetDirectory $AssetDirectory -Version $Version
$assets = @($layout.AssetNames | ForEach-Object { Join-Path $AssetDirectory $_ })

function Assert-RecoverableDraft([switch]$RequireComplete) {
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('context-mini-release-state-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $arguments = @{
            Repository = $Repository
            Tag = $Tag
            Version = $Version
            SourceSha = $SourceSha
            GitHubOutput = $outputPath
            Json = $true
        }
        if ($RequireComplete) { $arguments.RequireCompleteDraft = $true }
        $stateJson = @(& (Join-Path $PSScriptRoot 'get-release-state.ps1') @arguments)
        $state = (($stateJson -join [Environment]::NewLine) | ConvertFrom-Json)
        if (-not [bool]$state.Recover) { throw 'The GitHub Release is no longer the matching recoverable draft.' }
        if ($RequireComplete) {
            $releaseJson = @(& gh release view $Tag --repo $Repository --json isDraft,assets)
            if ($LASTEXITCODE -ne 0) { throw "Unable to verify draft Release assets for $Tag." }
            $release = (($releaseJson -join [Environment]::NewLine) | ConvertFrom-Json)
            if (-not [bool]$release.isDraft) { throw 'The GitHub Release became published before its tested assets were verified.' }
            $null = Assert-ContextMiniReleaseAssetDigests -Release $release -AssetDirectory $AssetDirectory -Version $Version
        }
    }
    finally {
        if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath -Force }
    }
}

if ($Mode -ceq 'Create') {
    $arguments = @('release','create',$Tag) + $assets + @(
        '--repo',$Repository,
        '--target',$SourceSha,
        '--title',"Context Mini $Version",
        '--generate-notes',
        '--draft',
        '--latest=false'
    )
    if ($Version.Contains('-')) { $arguments += '--prerelease' }
    & gh @arguments
    if ($LASTEXITCODE -ne 0) { throw "gh release create failed with exit code $LASTEXITCODE; a partially uploaded draft remains recoverable if it was created." }
    Assert-RecoverableDraft -RequireComplete
    & gh release edit $Tag --repo $Repository --draft=false --latest=false
    if ($LASTEXITCODE -ne 0) { throw "gh release edit failed with exit code $LASTEXITCODE; retry will resume the same draft." }
    exit 0
}

Assert-RecoverableDraft
$uploadArguments = @('release','upload',$Tag) + $assets + @('--repo',$Repository,'--clobber')
& gh @uploadArguments
if ($LASTEXITCODE -ne 0) { throw "gh release upload failed with exit code $LASTEXITCODE; the draft remains recoverable." }
Assert-RecoverableDraft -RequireComplete
& gh release edit $Tag --repo $Repository --draft=false --latest=false
if ($LASTEXITCODE -ne 0) { throw "gh release edit failed with exit code $LASTEXITCODE; retry will resume the same draft." }
