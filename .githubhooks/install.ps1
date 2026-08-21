[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$NoreplyEmail,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Invoke-Git {
    param([string[]]$Arguments, [int[]]$AllowedExitCodes = @(0))
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $output = @(& git -C $root @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "Git command failed with exit code $exitCode."
    }
    return [PSCustomObject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-LocalConfigState {
    param([string]$Key)
    $result = Invoke-Git @('config', '--local', '--get-all', $Key) @(0, 1)
    return [PSCustomObject]@{
        Present = $result.ExitCode -eq 0
        Values = @($result.Output | ForEach-Object { [string]$_ })
    }
}

function Restore-LocalConfigState {
    param([string]$Key, $State)
    $null = Invoke-Git @('config', '--local', '--unset-all', $Key) @(0, 1, 5)
    if ($State.Present) {
        foreach ($value in $State.Values) { $null = Invoke-Git @('config', '--local', '--add', $Key, $value) }
    }
}

$gitRootResult = Invoke-Git @('rev-parse', '--show-toplevel')
$gitRoot = ([string]($gitRootResult.Output | Select-Object -Last 1)).Trim()
if ([System.IO.Path]::GetFullPath($gitRoot) -cne $root) {
    throw "Expected .githubhooks to live at the repository root: $root"
}

& node --version | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Node.js is required by the committed Git hooks.' }

if (-not [string]::IsNullOrWhiteSpace($NoreplyEmail) -and
    $NoreplyEmail -cnotmatch '^[^@\s]+@users\.noreply\.github\.com$') {
    throw 'NoreplyEmail must be a GitHub-provided users.noreply.github.com address.'
}

$effectiveHooks = Invoke-Git @('config', '--get', 'core.hooksPath') @(0, 1)
$effectiveHooksPath = if ($effectiveHooks.ExitCode -eq 0) {
    ([string]($effectiveHooks.Output | Select-Object -Last 1)).Trim()
}
else {
    ''
}
if (-not [string]::IsNullOrWhiteSpace($effectiveHooksPath) -and $effectiveHooksPath -cne '.githubhooks' -and -not $Force) {
    $origin = Invoke-Git @('config', '--show-origin', '--get', 'core.hooksPath') @(0, 1)
    $originLabel = if ($origin.ExitCode -eq 0) { ([string]($origin.Output | Select-Object -Last 1)).Trim() } else { 'unknown origin' }
    throw "An effective core.hooksPath is already configured ($originLabel). Re-run with -Force only after migrating or chaining those hooks."
}

if ([string]::IsNullOrWhiteSpace($effectiveHooksPath)) {
    $hooksResult = Invoke-Git @('rev-parse', '--git-path', 'hooks')
    $hooksValue = ([string]($hooksResult.Output | Select-Object -Last 1)).Trim()
    $defaultHooksPath = if ([System.IO.Path]::IsPathRooted($hooksValue)) {
        [System.IO.Path]::GetFullPath($hooksValue)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $root $hooksValue))
    }
    $activeDefaultHooks = @(Get-ChildItem -LiteralPath $defaultHooksPath -Force -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notlike '*.sample'
    } | ForEach-Object { $_.Name })
    if ($activeDefaultHooks.Count -gt 0 -and -not $Force) {
        throw "Default Git hooks already exist ($($activeDefaultHooks -join ', ')). Re-run with -Force only after migrating or chaining them."
    }
}

if (-not $PSCmdlet.ShouldProcess($root, 'Configure repository-local Git email privacy hooks')) {
    Write-Output 'Preview: core.hooksPath would be set to .githubhooks and user.useConfigOnly would be enabled.'
    return
}

$states = @{
    'core.hooksPath' = Get-LocalConfigState 'core.hooksPath'
    'user.useConfigOnly' = Get-LocalConfigState 'user.useConfigOnly'
    'user.email' = Get-LocalConfigState 'user.email'
}

try {
    $null = Invoke-Git @('config', '--local', 'core.hooksPath', '.githubhooks')
    $null = Invoke-Git @('config', '--local', 'user.useConfigOnly', 'true')
    if (-not [string]::IsNullOrWhiteSpace($NoreplyEmail)) {
        $null = Invoke-Git @('config', '--local', 'user.email', $NoreplyEmail)
    }

    $configuredPath = Invoke-Git @('config', '--local', '--get', 'core.hooksPath')
    if (([string]($configuredPath.Output | Select-Object -Last 1)).Trim() -cne '.githubhooks') {
        throw 'Configured core.hooksPath did not persist as .githubhooks.'
    }

    & node (Join-Path $PSScriptRoot 'check-email-policy.mjs') --mode staged --root $root
    if ($LASTEXITCODE -ne 0) { throw 'The current Git email/content policy check failed.' }
}
catch {
    foreach ($key in @('user.email', 'user.useConfigOnly', 'core.hooksPath')) {
        Restore-LocalConfigState $key $states[$key]
    }
    throw 'Hook installation failed; the previous repository-local Git configuration was restored.'
}

Write-Output 'Installed repository hooks: pre-commit, commit-msg, pre-push.'
