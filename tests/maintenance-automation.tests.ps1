[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dependabot = Join-Path $root '.github\dependabot.yml'
$codeql = Join-Path $root '.github\workflows\codeql.yml'
$ciRelease = Join-Path $root '.github\workflows\ci-release.yml'
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

Run 'The .NET SDK is not pinned and CI installs the latest .NET 11 SDK' {
    Assert (-not (Test-Path -LiteralPath $globalJson)) 'global.json would pin or restrict the .NET SDK again.'
    $text = [IO.File]::ReadAllText($dependabot)
    Assert (-not $text.Contains('package-ecosystem: dotnet-sdk')) 'Dependabot tracks a global.json that no longer exists.'
    foreach ($workflow in @($ciRelease, $codeql)) {
        $name = Split-Path -Leaf $workflow
        $workflowText = [IO.File]::ReadAllText($workflow)
        Assert ($workflowText.Contains('dotnet-version: 11.0.x')) "$name does not install the latest .NET 11 SDK."
        Assert (-not $workflowText.Contains('global-json-file')) "$name still reads a global.json."
    }
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
