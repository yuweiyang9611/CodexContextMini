[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$SelfContained
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'The win-x64 publish script must run on an x64 process.'
}
$artifacts = Join-Path $root '.artifacts'
$env:DOTNET_CLI_HOME = Join-Path $artifacts 'dotnet-home'
$env:NUGET_PACKAGES = Join-Path $artifacts 'nuget-packages'
$null = New-Item -ItemType Directory -Path $env:DOTNET_CLI_HOME, $env:NUGET_PACKAGES -Force
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $publishFolder = if ($SelfContained) { 'publish\win-x64-self-contained' } else { 'publish\win-x64' }
    $OutputDirectory = Join-Path $artifacts $publishFolder
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
$allowedRoot = [IO.Path]::GetFullPath($artifacts).TrimEnd('\') + [IO.Path]::DirectorySeparatorChar
if (-not $output.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Publish output must stay under $artifacts"
}
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
$null = New-Item -ItemType Directory -Path $output -Force

$project = Join-Path $root 'src\ContextMini\ContextMini.csproj'
$nugetConfig = Join-Path $root 'NuGet.Config'
if ($SelfContained) {
    & dotnet restore $project --configfile $nugetConfig --runtime win-x64 --source https://api.nuget.org/v3/index.json
    if ($LASTEXITCODE -ne 0) { throw "Self-contained dotnet restore failed with exit code $LASTEXITCODE." }
    & dotnet publish $project -c Release --runtime win-x64 --self-contained true --no-restore -p:DebugType=None -o $output
    if ($LASTEXITCODE -ne 0) { throw "Self-contained dotnet publish failed with exit code $LASTEXITCODE." }
}
else {
    & dotnet restore $project --configfile $nugetConfig
    if ($LASTEXITCODE -ne 0) { throw "Framework-dependent dotnet restore failed with exit code $LASTEXITCODE." }
    & dotnet publish $project -c Release --self-contained false --no-restore -p:DebugType=None -o $output
    if ($LASTEXITCODE -ne 0) { throw "Framework-dependent dotnet publish failed with exit code $LASTEXITCODE." }
}

$exe = Join-Path $output 'ContextMini.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Published executable is missing: $exe" }
Write-Output $output
