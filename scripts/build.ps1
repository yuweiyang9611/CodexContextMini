[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifacts = Join-Path $root '.artifacts'
$env:DOTNET_CLI_HOME = Join-Path $artifacts 'dotnet-home'
$env:NUGET_PACKAGES = Join-Path $artifacts 'nuget-packages'
$null = New-Item -ItemType Directory -Path $env:DOTNET_CLI_HOME, $env:NUGET_PACKAGES -Force

& dotnet restore (Join-Path $root 'ContextMini.slnx') --configfile (Join-Path $root 'NuGet.Config')
if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed with exit code $LASTEXITCODE." }
& dotnet build (Join-Path $root 'ContextMini.slnx') -c $Configuration --no-restore
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed with exit code $LASTEXITCODE." }

Write-Output "Context Mini build succeeded: $Configuration"