[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolver = Join-Path $repositoryRoot 'scripts\resolve-version-change.ps1'
$setter = Join-Path $repositoryRoot 'scripts\set-version.ps1'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Git {
    param([string]$Root, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $output = & git -C $Root @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join ' ')" }
    return $output
}

function Read-Plan {
    param([string]$Root, [string]$Before, [string]$Current)
    $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $resolver `
        -RepositoryRoot $Root -BeforeCommit $Before -CurrentCommit $Current -Json
    if ($LASTEXITCODE -ne 0) { throw "resolve-version-change.ps1 failed with exit code $LASTEXITCODE." }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Write-Manifest {
    param([string]$Root, [string]$Version)
    $directory = Join-Path $Root 'plugins\context-window-manager\.codex-plugin'
    $null = New-Item -ItemType Directory -Path $directory -Force
    $json = "{`n  `"name`": `"context-window-manager`",`n  `"version`": `"$Version`"`n}`n"
    [System.IO.File]::WriteAllText((Join-Path $directory 'plugin.json'), $json, $utf8)
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('context-window-release-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempRoot
try {
    $null = Invoke-Git $tempRoot init -b main
    $null = Invoke-Git $tempRoot config user.name 'release-test'
    $null = Invoke-Git $tempRoot config user.email 'release-test@example.invalid'

    Write-Manifest $tempRoot '1.0.0+codex.first'
    $null = Invoke-Git $tempRoot add -- 'plugins/context-window-manager/.codex-plugin/plugin.json'
    $null = Invoke-Git $tempRoot commit -m 'baseline'
    $baseline = ([string](Invoke-Git $tempRoot rev-parse HEAD | Select-Object -Last 1)).Trim()

    Write-Manifest $tempRoot '1.0.0+codex.second'
    $null = Invoke-Git $tempRoot add -- 'plugins/context-window-manager/.codex-plugin/plugin.json'
    $null = Invoke-Git $tempRoot commit -m 'cachebuster only'
    $cachebuster = ([string](Invoke-Git $tempRoot rev-parse HEAD | Select-Object -Last 1)).Trim()

    $plan = Read-Plan $tempRoot $baseline $cachebuster
    Assert-True (-not [bool]$plan.changed) 'Build metadata alone must not trigger a release.'
    Assert-True ([string]$plan.currentReleaseVersion -ceq '1.0.0') 'Unexpected release version after cachebuster change.'
    Write-Output 'PASS build metadata does not trigger a release'
    $passed++

    Write-Manifest $tempRoot '1.0.1'
    $null = Invoke-Git $tempRoot add -- 'plugins/context-window-manager/.codex-plugin/plugin.json'
    $null = Invoke-Git $tempRoot commit -m 'release bump'
    $release = ([string](Invoke-Git $tempRoot rev-parse HEAD | Select-Object -Last 1)).Trim()

    $plan = Read-Plan $tempRoot $cachebuster $release
    Assert-True ([bool]$plan.changed) 'A release SemVer change must trigger a release.'
    Assert-True ([string]$plan.previousReleaseVersion -ceq '1.0.0') 'Unexpected previous release version.'
    Assert-True ([string]$plan.currentReleaseVersion -ceq '1.0.1') 'Unexpected current release version.'
    Assert-True ([string]$plan.tag -ceq 'v1.0.1') 'Unexpected release tag.'
    Write-Output 'PASS release SemVer change triggers exactly one new version'
    $passed++

    $plan = Read-Plan $tempRoot ('f' * 40) $release
    Assert-True (-not [bool]$plan.changed) 'An unavailable previous commit must skip release safely.'
    Assert-True ([string]$plan.reason -match 'unavailable') 'Unavailable previous commit diagnostic is missing.'
    Write-Output 'PASS unavailable previous commit establishes a safe no-release baseline'
    $passed++

    $emptyRoot = Join-Path $tempRoot 'empty-history'
    $null = New-Item -ItemType Directory -Path $emptyRoot
    $null = Invoke-Git $emptyRoot init -b main
    $null = Invoke-Git $emptyRoot config user.name 'release-test'
    $null = Invoke-Git $emptyRoot config user.email 'release-test@example.invalid'
    [System.IO.File]::WriteAllText((Join-Path $emptyRoot 'README.md'), "baseline`n", $utf8)
    $null = Invoke-Git $emptyRoot add -- README.md
    $null = Invoke-Git $emptyRoot commit -m 'no manifest'
    $withoutManifest = ([string](Invoke-Git $emptyRoot rev-parse HEAD | Select-Object -Last 1)).Trim()
    Write-Manifest $emptyRoot '1.0.0'
    $null = Invoke-Git $emptyRoot add -- 'plugins/context-window-manager/.codex-plugin/plugin.json'
    $null = Invoke-Git $emptyRoot commit -m 'add manifest'
    $withManifest = ([string](Invoke-Git $emptyRoot rev-parse HEAD | Select-Object -Last 1)).Trim()
    $plan = Read-Plan $emptyRoot $withoutManifest $withManifest
    Assert-True (-not [bool]$plan.changed) 'Adding the first manifest must establish a baseline, not publish automatically.'
    Write-Output 'PASS first manifest establishes a no-release baseline'
    $passed++

    $setterRoot = Join-Path $tempRoot 'setter'
    foreach ($path in @('scripts', 'plugins\context-window-manager\.codex-plugin', 'plugins\context-window-manager\mcp', 'plugins\context-window-manager\ui')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $setterRoot $path) -Force
    }
    Copy-Item -LiteralPath $setter -Destination (Join-Path $setterRoot 'scripts\set-version.ps1')
    [System.IO.File]::WriteAllText((Join-Path $setterRoot 'plugins\context-window-manager\.codex-plugin\plugin.json'), "{`n  `"version`": `"1.0.0+codex.test`",`n  `"name`": `"context-window-manager`"`n}`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $setterRoot 'plugins\context-window-manager\mcp\server.mjs'), "const SERVER_VERSION = `"1.0.0`";`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $setterRoot 'plugins\context-window-manager\ui\context-window-control.html'), "appInfo: { name: `"context-window-manager-widget`", version: `"1.0.0`" }`n", $utf8)
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $setterRoot 'scripts\set-version.ps1') 'v1.0.1' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'set-version.ps1 failed.' }
    $updatedManifest = Get-Content -Raw (Join-Path $setterRoot 'plugins\context-window-manager\.codex-plugin\plugin.json') | ConvertFrom-Json
    Assert-True ([string]$updatedManifest.version -ceq '1.0.1') 'Version helper did not update the manifest.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $setterRoot 'plugins\context-window-manager\mcp\server.mjs')).Contains('"1.0.1"')) 'Version helper did not update the MCP server.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $setterRoot 'plugins\context-window-manager\ui\context-window-control.html')).Contains('version: "1.0.1"')) 'Version helper did not update the widget.'
    Write-Output 'PASS manual version helper updates all public version fields'
    $passed++
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Output "RESULT passed=$passed failed=0"
