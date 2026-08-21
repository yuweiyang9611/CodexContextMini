[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$normalized = $Version.Trim()
if ($normalized.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
    $normalized = $normalized.Substring(1)
}

$releaseSemVerPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?$'
if ($normalized -cnotmatch $releaseSemVerPattern) {
    throw "Version must be release SemVer such as 0.2.1 or 0.3.0-beta.1; build metadata is managed separately."
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $root 'plugins\context-window-manager\.codex-plugin\plugin.json'
$serverPath = Join-Path $root 'plugins\context-window-manager\mcp\server.mjs'
$uiPath = Join-Path $root 'plugins\context-window-manager\ui\context-window-control.html'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$updates = @(
    [PSCustomObject]@{
        Path = $manifestPath
        Pattern = '(?m)("version"\s*:\s*")[^"]+("\s*,)'
        Replacement = { param($match) $match.Groups[1].Value + $normalized + $match.Groups[2].Value }
    },
    [PSCustomObject]@{
        Path = $serverPath
        Pattern = '(const SERVER_VERSION\s*=\s*")[^"]+(";)'
        Replacement = { param($match) $match.Groups[1].Value + $normalized + $match.Groups[2].Value }
    },
    [PSCustomObject]@{
        Path = $uiPath
        Pattern = '(appInfo:\s*\{\s*name:\s*"context-window-manager-widget",\s*version:\s*")[^"]+("\s*\})'
        Replacement = { param($match) $match.Groups[1].Value + $normalized + $match.Groups[2].Value }
    }
)

$plans = @()
foreach ($update in $updates) {
    $original = [System.IO.File]::ReadAllText($update.Path, [System.Text.Encoding]::UTF8)
    $matches = [System.Text.RegularExpressions.Regex]::Matches($original, $update.Pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one version field in $($update.Path), found $($matches.Count)."
    }
    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $original,
        $update.Pattern,
        [System.Text.RegularExpressions.MatchEvaluator]$update.Replacement,
        1
    )
    $plans += [PSCustomObject]@{ Path = $update.Path; Original = $original; Updated = $updated }
}

if (-not $PSCmdlet.ShouldProcess($root, "Set public release version to $normalized in manifest, MCP server, and widget")) {
    Write-Output "Preview: release version would become $normalized"
    return
}

$written = New-Object 'System.Collections.Generic.List[object]'
try {
    foreach ($plan in $plans) {
        if ($plan.Original -cne $plan.Updated) {
            [System.IO.File]::WriteAllText($plan.Path, $plan.Updated, $utf8)
            $written.Add($plan)
        }
    }
}
catch {
    foreach ($plan in $written) {
        [System.IO.File]::WriteAllText($plan.Path, $plan.Original, $utf8)
    }
    throw
}

Write-Output "Release version set to $normalized. Commit these files; CI will publish v$normalized after main passes."
