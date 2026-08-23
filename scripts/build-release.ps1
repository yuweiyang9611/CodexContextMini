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
$semver = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?$'
if ($version -cnotmatch $semver) { throw "VERSION is not release SemVer: $version" }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $root 'dist' }
$output = [IO.Path]::GetFullPath($(if([IO.Path]::IsPathRooted($OutputDirectory)){$OutputDirectory}else{Join-Path $root $OutputDirectory}))
$null = New-Item -ItemType Directory -Path $output -Force
$zip = Join-Path $output "ContextMini-v$version-win-x64.zip"
$checksums = Join-Path $output 'SHA256SUMS.txt'
foreach($path in @($zip,$checksums)){ if(Test-Path -LiteralPath $path){ throw "Refusing to overwrite release output: $path" } }
$stage = Join-Path $root ('.artifacts\release-stage\' + [guid]::NewGuid().ToString('N'))
try {
    $publishOutput = @(& (Join-Path $PSScriptRoot 'publish.ps1') -OutputDirectory $stage)
    if ($LASTEXITCODE -ne 0) { throw "WPF publish failed with exit code $LASTEXITCODE." }
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'ContextMini.exe'))) { throw 'ContextMini.exe is missing from publish output.' }
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $stage 'LICENSE')
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $names=@($archive.Entries | ForEach-Object FullName)
        foreach($required in @('ContextMini.exe','ContextMini.dll','ContextMini.runtimeconfig.json','LICENSE')){ if($names -cnotcontains $required){ throw "Release ZIP is missing $required" } }
    }
    finally { $archive.Dispose() }
}
finally { if(Test-Path -LiteralPath $stage){ Remove-Item -LiteralPath $stage -Recurse -Force } }
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($checksums,"$hash  $(Split-Path -Leaf $zip)`n",(New-Object Text.UTF8Encoding($false)))
$result=[PSCustomObject]@{ version=$version; tag="v$version"; commit=$commit; archive=$zip; checksums=$checksums }
if($Json){ $result | ConvertTo-Json -Compress }else{ $result }