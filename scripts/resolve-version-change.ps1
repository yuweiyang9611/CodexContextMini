[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string]$BeforeCommit,
    [string]$CurrentCommit = 'HEAD',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..'
}
$root = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $RepositoryRoot -Force).FullName)
$manifestRelativePath = 'plugins/context-window-manager/.codex-plugin/plugin.json'
$semverPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'

function Resolve-Commit {
    param([string]$Commit, [switch]$AllowMissing)
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $output = & git -C $root rev-parse --verify ($Commit + '^{commit}') 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($exitCode -ne 0) {
        if ($AllowMissing) { return $null }
        throw "Unable to resolve commit: $Commit"
    }
    return ([string]($output | Select-Object -Last 1)).Trim()
}

function Read-VersionAtCommit {
    param([string]$Commit, [switch]$AllowMissing)
    $spec = $Commit + ':' + $manifestRelativePath
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $content = & git -C $root show $spec 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($exitCode -ne 0) {
        if ($AllowMissing) { return $null }
        throw "Unable to read $manifestRelativePath from commit $Commit."
    }

    try {
        $manifest = (($content -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    catch {
        throw "Invalid plugin manifest JSON at commit ${Commit}: $($_.Exception.Message)"
    }
    $fullVersion = [string]$manifest.version
    if ($fullVersion -cnotmatch $semverPattern) {
        throw "Manifest version at commit $Commit is not strict SemVer: $fullVersion"
    }
    return [PSCustomObject]@{
        full = $fullVersion
        release = ($fullVersion -split '\+', 2)[0]
    }
}

$currentSha = Resolve-Commit $CurrentCommit
$currentVersion = Read-VersionAtCommit $currentSha
$beforeValue = $BeforeCommit.Trim()
$previousSha = $null
$previousVersion = $null
$changed = $false
$reason = $null

if ([string]::IsNullOrWhiteSpace($beforeValue) -or $beforeValue -cmatch '^0{40}$') {
    $reason = 'No previous commit was supplied; the current version is recorded as a baseline.'
}
else {
    $previousSha = Resolve-Commit $beforeValue -AllowMissing
    if ($null -eq $previousSha) {
        $reason = 'The previous commit is unavailable; release is skipped because a version change cannot be proven.'
    }
    else {
        $previousVersion = Read-VersionAtCommit $previousSha -AllowMissing
        if ($null -eq $previousVersion) {
            $reason = 'The previous commit has no plugin manifest; the current version is recorded as a baseline.'
        }
        else {
            $changed = $previousVersion.release -cne $currentVersion.release
            $reason = if ($changed) {
                "Release version changed from $($previousVersion.release) to $($currentVersion.release)."
            }
            else {
                "Release version remains $($currentVersion.release)."
            }
        }
    }
}

$result = [PSCustomObject]@{
    changed = $changed
    reason = $reason
    previousCommit = $previousSha
    previousManifestVersion = if ($null -eq $previousVersion) { $null } else { $previousVersion.full }
    previousReleaseVersion = if ($null -eq $previousVersion) { $null } else { $previousVersion.release }
    currentCommit = $currentSha
    currentManifestVersion = $currentVersion.full
    currentReleaseVersion = $currentVersion.release
    tag = "v$($currentVersion.release)"
}

if ($Json) { $result | ConvertTo-Json -Compress } else { $result }
