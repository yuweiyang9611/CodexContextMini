[CmdletBinding()]
param([string]$RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    # A PS7 parent can leak incompatible module paths into powershell.exe.
    $env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
}
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Join-Path $PSScriptRoot '..' }
$root = [IO.Path]::GetFullPath((Get-Item -LiteralPath $RepositoryRoot -Force).FullName)

# Pin the official release asset and its GitHub-published SHA-256. Do not replace
# these constants with a moving latest URL or an unverified package-manager install.
$actionlintVersion = '1.7.12'
$archiveName = "actionlint_${actionlintVersion}_windows_amd64.zip"
$archiveUrl = "https://github.com/rhysd/actionlint/releases/download/v$actionlintVersion/$archiveName"
$expectedSha256 = '6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9'
$workflows = [string[]]@(
    Get-ChildItem -LiteralPath (Join-Path $root '.github\workflows') -File |
        Where-Object { $_.Extension -in @('.yml','.yaml') } |
        ForEach-Object FullName
)
[Array]::Sort($workflows, [StringComparer]::Ordinal)
if ($workflows.Count -eq 0) { throw 'No GitHub Actions workflows were found.' }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('context-mini-actionlint-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$resolvedWork = [IO.Path]::GetFullPath($tempRoot)
if (-not $resolvedWork.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe actionlint temporary directory.' }
try {
    $null = New-Item -ItemType Directory -Path $resolvedWork
    $archivePath = Join-Path $resolvedWork $archiveName
    Invoke-WebRequest -UseBasicParsing -Uri $archiveUrl -OutFile $archivePath
    $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hashBytes = $sha.ComputeHash($archiveStream) }
        finally { $sha.Dispose() }
    }
    finally { $archiveStream.Dispose() }
    $actualSha256 = ([BitConverter]::ToString($hashBytes)).Replace('-','').ToLowerInvariant()
    if ($actualSha256 -cne $expectedSha256) { throw "actionlint archive SHA-256 mismatch: $actualSha256" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $resolvedWork)
    $actionlint = Join-Path $resolvedWork 'actionlint.exe'
    if (-not (Test-Path -LiteralPath $actionlint -PathType Leaf)) { throw 'Verified actionlint archive contains no actionlint.exe.' }

    # v1.7.12 predates GitHub's concurrency.queue schema addition. Ignore only
    # that exact known false positive while GitHub itself validates queue: max.
    # Upstream: https://github.com/rhysd/actionlint/issues/657
    # Use regex hex escapes instead of literal quotes: Windows PowerShell 5.1
    # removes embedded quotes while constructing native process arguments.
    $queueFalsePositive = 'unexpected key \x22queue\x22 for \x22concurrency\x22 section'
    & $actionlint -no-color -ignore $queueFalsePositive @workflows
    if ($LASTEXITCODE -ne 0) { throw "actionlint failed with exit code $LASTEXITCODE." }
    Write-Output "actionlint $actionlintVersion verified $($workflows.Count) workflow(s)."
}
finally {
    if (Test-Path -LiteralPath $resolvedWork) { Remove-Item -LiteralPath $resolvedWork -Recurse -Force }
}
