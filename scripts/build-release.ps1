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

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..'
}
$root = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $RepositoryRoot -Force).FullName)
if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    throw "RepositoryRoot is not a Git worktree: $root"
}

$commitOutput = & git -C $root rev-parse --verify ($Commitish + '^{commit}') 2>&1
if ($LASTEXITCODE -ne 0) { throw "Unable to resolve commit '$Commitish': $($commitOutput -join ' ')" }
$commit = ([string]($commitOutput | Select-Object -Last 1)).Trim()

$manifestSpec = $commit + ':plugins/context-window-manager/.codex-plugin/plugin.json'
$manifestOutput = & git -C $root show $manifestSpec 2>&1
if ($LASTEXITCODE -ne 0) { throw "Unable to read the plugin manifest from ${commit}: $($manifestOutput -join ' ')" }
$manifest = (($manifestOutput -join [Environment]::NewLine) | ConvertFrom-Json)
$manifestVersion = [string]$manifest.version
$semverPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
if ($manifestVersion -cnotmatch $semverPattern) { throw "Manifest version is not strict SemVer: $manifestVersion" }
$releaseVersion = ($manifestVersion -split '\+', 2)[0]

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $root 'dist'
}
$output = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    [System.IO.Path]::GetFullPath($OutputDirectory)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $root $OutputDirectory))
}
$null = New-Item -ItemType Directory -Path $output -Force

$pluginZip = Join-Path $output ("context-window-manager-v$releaseVersion.zip")
$marketplaceZip = Join-Path $output ("CodexContextPlugin-v$releaseVersion.zip")
$checksums = Join-Path $output 'SHA256SUMS.txt'
foreach ($path in @($pluginZip, $marketplaceZip, $checksums)) {
    if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite existing release output: $path" }
}

$pluginTree = $commit + ':plugins/context-window-manager'
& git -C $root archive --format=zip ("--prefix=context-window-manager-$releaseVersion/") ("--output=$pluginZip") $pluginTree
if ($LASTEXITCODE -ne 0) { throw 'git archive failed for the plugin bundle.' }

& git -C $root archive --format=zip ("--prefix=CodexContextPlugin-$releaseVersion/") ("--output=$marketplaceZip") $commit .agents plugins README.md LICENSE
if ($LASTEXITCODE -ne 0) { throw 'git archive failed for the marketplace bundle.' }

Add-Type -AssemblyName System.IO.Compression.FileSystem
function Assert-ZipEntry {
    param([string]$ZipPath, [string]$EntryName)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if (-not @($archive.Entries | Where-Object { $_.FullName -ceq $EntryName })) {
            throw "Release archive is missing '$EntryName': $ZipPath"
        }
    }
    finally {
        $archive.Dispose()
    }
}

Assert-ZipEntry $pluginZip "context-window-manager-$releaseVersion/.codex-plugin/plugin.json"
Assert-ZipEntry $pluginZip "context-window-manager-$releaseVersion/.mcp.json"
Assert-ZipEntry $marketplaceZip "CodexContextPlugin-$releaseVersion/.agents/plugins/marketplace.json"
Assert-ZipEntry $marketplaceZip "CodexContextPlugin-$releaseVersion/plugins/context-window-manager/.codex-plugin/plugin.json"

$hashLines = @()
foreach ($path in @($pluginZip, $marketplaceZip)) {
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashLines += "$hash  $(Split-Path -Leaf $path)"
}
[System.IO.File]::WriteAllLines($checksums, [string[]]$hashLines, (New-Object System.Text.UTF8Encoding($false)))

$result = [PSCustomObject]@{
    manifestVersion    = $manifestVersion
    releaseVersion    = $releaseVersion
    tag               = "v$releaseVersion"
    commit            = $commit
    pluginArchive     = $pluginZip
    marketplaceArchive = $marketplaceZip
    checksums          = $checksums
}

if ($Json) { $result | ConvertTo-Json -Compress } else { $result }
