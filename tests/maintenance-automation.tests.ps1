[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dependabot = Join-Path $root '.github\dependabot.yml'
$codeql = Join-Path $root '.github\workflows\codeql.yml'
$globalJson = Join-Path $root 'global.json'
$passed = 0

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Run([string]$Name, [scriptblock]$Test) {
    & $Test
    $script:passed++
    Write-Output "PASS $Name"
}

Run 'Dependabot tracks immutable GitHub Actions references' {
    $text = [IO.File]::ReadAllText($dependabot)
    Assert ($text.Contains('package-ecosystem: github-actions')) 'Dependabot does not track GitHub Actions.'
    Assert ($text.Contains('prefix: chore(actions)')) 'GitHub Actions updates are not identifiable.'
    Assert ($text.Contains('interval: weekly')) 'Dependabot is not scheduled weekly.'
}

Run 'Dependabot tracks the pinned .NET SDK and self-contained runtime source' {
    $text = [IO.File]::ReadAllText($dependabot)
    Assert ($text.Contains('package-ecosystem: dotnet-sdk')) 'Dependabot does not track global.json.'
    Assert ($text.Contains('prefix: chore(dotnet)')) '.NET SDK updates are not identifiable.'
    $settings = [IO.File]::ReadAllText($globalJson) | ConvertFrom-Json
    Assert (-not [bool]$settings.sdk.allowPrerelease) 'The release toolchain unexpectedly accepts prerelease SDKs.'
    Assert ([string]$settings.sdk.rollForward -ceq 'disable') 'The build does not use the exact reviewed SDK.'
}

Run 'CodeQL actions are immutable and least privilege' {
    $text = [IO.File]::ReadAllText($codeql)
    $matches = [regex]::Matches($text, 'github/codeql-action/(?:init|analyze)@(?<sha>[0-9a-f]{40})')
    Assert ($matches.Count -eq 2) 'CodeQL init/analyze must both use full commit SHAs.'
    Assert (-not $text.Contains('github/codeql-action/init@v')) 'CodeQL init uses a moving tag.'
    Assert ($text.Contains('security-events: write')) 'CodeQL cannot upload results.'
    Assert ($text.Contains('build-mode: manual')) 'CodeQL is not analyzing the real WPF build.'
    Assert (-not $text.Contains('contents: write')) 'CodeQL can unexpectedly modify repository contents.'
}

Write-Output "RESULT passed=$passed failed=0"
