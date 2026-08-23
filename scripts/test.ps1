[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$NoBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $NoBuild) {
    & (Join-Path $PSScriptRoot 'build.ps1') -Configuration $Configuration
    if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE." }
}
& dotnet run --project (Join-Path $root 'tests\ContextMini.Tests\ContextMini.Tests.csproj') -c $Configuration --no-build
if ($LASTEXITCODE -ne 0) { throw "Context Mini tests failed with exit code $LASTEXITCODE." }
& dotnet run --project (Join-Path $root 'tests\ContextMini.WpfTests\ContextMini.WpfTests.csproj') -c $Configuration --no-build
if ($LASTEXITCODE -ne 0) { throw "Context Mini WPF tests failed with exit code $LASTEXITCODE." }
& (Join-Path $root 'tests\appearance-xaml.tests.ps1')
if ($LASTEXITCODE -ne 0) { throw "Appearance XAML tests failed with exit code $LASTEXITCODE." }