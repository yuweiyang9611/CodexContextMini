[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$Commitish = 'HEAD',
    [string]$OutputDirectory,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Join-Path $PSScriptRoot '..' }
$root = [IO.Path]::GetFullPath((Get-Item -LiteralPath $RepositoryRoot -Force).FullName)
$scriptRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not [string]::Equals($root, $scriptRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'RepositoryRoot must be the repository containing this build-release.ps1.'
}
Import-Module (Join-Path $PSScriptRoot 'ReleaseAutomation.psm1') -Force
$savedPreference = $ErrorActionPreference
try { $ErrorActionPreference = 'SilentlyContinue'; $dirty = @(& git -C $root status --porcelain --untracked-files=normal 2>$null); $dirtyCode = $LASTEXITCODE }
finally { $ErrorActionPreference = $savedPreference }
if ($dirtyCode -ne 0) { throw 'Unable to verify release worktree cleanliness.' }
if ($dirty.Count -gt 0) { throw 'Release assets require a clean worktree matching the requested commit.' }
$commitOutput = @(& git -C $root rev-parse --verify ($Commitish + '^{commit}') 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Unable to resolve commit '$Commitish'." }
$commit = ([string]($commitOutput | Select-Object -Last 1)).Trim()
$head = ([string](@(& git -C $root rev-parse HEAD) | Select-Object -Last 1)).Trim()
if ($head -cne $commit) { throw 'build-release.ps1 requires the requested commit to be checked out.' }
$versionOutput = @(& git -C $root show ($commit + ':VERSION') 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to read VERSION from the release commit.' }
$version = (($versionOutput -join [Environment]::NewLine).Trim())
$layout = Get-ContextMiniReleaseLayout -Version $version
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $root 'dist' }
$output = [IO.Path]::GetFullPath($(if([IO.Path]::IsPathRooted($OutputDirectory)){$OutputDirectory}else{Join-Path $root $OutputDirectory}))
$outputParent = Split-Path -Parent $output
$outputLeaf = Split-Path -Leaf $output
if ([string]::IsNullOrWhiteSpace($outputLeaf)) { throw 'OutputDirectory must identify a child directory.' }
$null = New-Item -ItemType Directory -Path $outputParent -Force
if (Test-Path -LiteralPath $output) {
    $existingOutput = @(Get-ChildItem -LiteralPath $output -Force)
    if ($existingOutput.Count -gt 0) { throw "Refusing to replace non-empty release output directory: $output" }
}
$stageId = [guid]::NewGuid().ToString('N')
$stageRoot = Join-Path $root ('.artifacts\release-stage\' + $stageId)
$assetStage = Join-Path $outputParent (".$outputLeaf.release-assets-" + $stageId)
$null = New-Item -ItemType Directory -Path $assetStage
$stagedFrameworkZip = Join-Path $assetStage $layout.FrameworkArchive
$stagedSelfContainedZip = Join-Path $assetStage $layout.SelfContainedArchive
$stagedChecksums = Join-Path $assetStage $layout.Checksums
$frameworkZip = Join-Path $output (Split-Path -Leaf $stagedFrameworkZip)
$selfContainedZip = Join-Path $output (Split-Path -Leaf $stagedSelfContainedZip)
$checksums = Join-Path $output 'SHA256SUMS.txt'

function New-ReleaseArchive {
    param(
        [Parameter(Mandatory=$true)][string]$Stage,
        [Parameter(Mandatory=$true)][string]$ArchivePath,
        [Parameter(Mandatory=$true)][ValidateSet('FrameworkDependent','SelfContained')][string]$Kind
    )
    $publishArguments=@{ OutputDirectory=$Stage }
    if($Kind -ceq 'SelfContained'){ $publishArguments.SelfContained=$true }
    $publishOutput = @(& (Join-Path $PSScriptRoot 'publish.ps1') @publishArguments)
    if ($LASTEXITCODE -ne 0) { throw "WPF publish failed with exit code $LASTEXITCODE ($Kind)." }
    if (-not (Test-Path -LiteralPath (Join-Path $Stage 'ContextMini.exe'))) { throw "ContextMini.exe is missing from publish output ($Kind)." }
    if ($Kind -ceq 'SelfContained') {
        if ([string]::IsNullOrWhiteSpace($env:NUGET_PACKAGES)) { throw 'publish.ps1 did not expose the restored NuGet package root.' }
        $null = Add-ContextMiniRuntimePackNotices -PublishDirectory $Stage -PackageRoot $env:NUGET_PACKAGES
    }
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $Stage 'LICENSE')
    New-ContextMiniDeterministicZip -SourceDirectory $Stage -ArchivePath $ArchivePath
    Assert-ContextMiniArchiveManifest -ArchivePath $ArchivePath -Kind $Kind
}

$frameworkStage = Join-Path $stageRoot 'framework-dependent'
$selfContainedStage = Join-Path $stageRoot 'self-contained'
try {
    New-ReleaseArchive -Stage $frameworkStage -ArchivePath $stagedFrameworkZip -Kind FrameworkDependent
    New-ReleaseArchive -Stage $selfContainedStage -ArchivePath $stagedSelfContainedZip -Kind SelfContained
    $stagedArchives=@($stagedFrameworkZip,$stagedSelfContainedZip) | Sort-Object { Split-Path -Leaf $_ }
    $checksumLines=@($stagedArchives | ForEach-Object {
        $hash=Get-ContextMiniSha256 -Path $_
        "$hash  $(Split-Path -Leaf $_)"
    })
    [IO.File]::WriteAllText($stagedChecksums,($checksumLines -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
    $null = Assert-ContextMiniReleaseAssetDirectory -AssetDirectory $assetStage -Version $version

    if (Test-Path -LiteralPath $output) {
        $existingOutput = @(Get-ChildItem -LiteralPath $output -Force)
        if ($existingOutput.Count -gt 0) { throw "Release output became non-empty while packaging: $output" }
        [IO.Directory]::Delete($output, $false)
    }
    [IO.Directory]::Move($assetStage, $output)
}
finally {
    if(Test-Path -LiteralPath $stageRoot){ Remove-Item -LiteralPath $stageRoot -Recurse -Force }
    if(Test-Path -LiteralPath $assetStage){ Remove-Item -LiteralPath $assetStage -Recurse -Force }
}
$archives=@($frameworkZip,$selfContainedZip) | Sort-Object { Split-Path -Leaf $_ }
$result=[PSCustomObject]@{
    version=$version
    tag="v$version"
    commit=$commit
    archive=$frameworkZip
    frameworkDependentArchive=$frameworkZip
    selfContainedArchive=$selfContainedZip
    archives=$archives
    checksums=$checksums
}
if($Json){ $result | ConvertTo-Json -Compress }else{ $result }
