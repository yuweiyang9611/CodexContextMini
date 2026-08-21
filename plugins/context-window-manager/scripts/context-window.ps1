[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'apply', 'reset', 'estimate', 'hook', 'help')]
    [string]$Command = 'status',

    [ValidateSet('auto', 'compact', 'balanced', '1m', 'custom')]
    [string]$Profile = 'auto',

    [string]$Model,
    [long]$Tokens = 0,
    [long]$CompactAt = 0,

    [ValidateSet('total', 'body_after_prefix')]
    [string]$Scope = 'total',

    [Alias('LiteralPath')]
    [string[]]$Path,

    [AllowEmptyString()]
    [string]$Text,

    [string]$ProjectRoot,
    [long]$MaxFileBytes = 33554432,
    [string]$ExpectedConfigSha256,
    [string]$ExpectedStateSha256,
    [switch]$Force,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$script:BeginMarker = '# >>> context-window-manager (managed; use the plugin to edit)'
$script:EndMarker = '# <<< context-window-manager'
$script:ManagedKeys = @(
    'model_context_window',
    'model_auto_compact_token_limit',
    'model_auto_compact_token_limit_scope'
)
$script:Catalog = $null
$script:HookMode = $false
$script:TextWasBound = $PSBoundParameters.ContainsKey('Text')

function Stop-Manager {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$Code = 2
    )

    if ($script:HookMode) {
        throw $Message
    }
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Write-JsonResult {
    param([Parameter(Mandatory = $true)]$Value)
    $Value | ConvertTo-Json -Depth 10 -Compress
}

function Format-TokenCount {
    param($Value)
    if ($null -eq $Value) { return 'unknown' }
    return ('{0:N0}' -f [long]$Value)
}

function Resolve-ProjectRoot {
    param(
        [string]$ExplicitRoot,
        [string]$StartPath
    )

    $hasExplicitRoot = -not [string]::IsNullOrWhiteSpace($ExplicitRoot)
    $candidate = if ($hasExplicitRoot) { $ExplicitRoot } else { $StartPath }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = (Get-Location).Path
    }

    try {
        $item = Get-Item -LiteralPath $candidate -Force
    }
    catch {
        Stop-Manager "Project path does not exist: $candidate" 4
    }

    if (-not $item.PSIsContainer) {
        $item = $item.Directory
    }

    if ($hasExplicitRoot) {
        return [System.IO.Path]::GetFullPath($item.FullName)
    }

    $fallback = $item.FullName
    $cursor = $item
    while ($null -ne $cursor) {
        $hasMarker =
            (Test-Path -LiteralPath (Join-Path $cursor.FullName '.git')) -or
            (Test-Path -LiteralPath (Join-Path $cursor.FullName '.agents')) -or
            (Test-Path -LiteralPath (Join-Path $cursor.FullName '.codex'))
        if ($hasMarker) {
            return [System.IO.Path]::GetFullPath($cursor.FullName)
        }
        $cursor = $cursor.Parent
    }

    return [System.IO.Path]::GetFullPath($fallback)
}

function Get-ProjectPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$CreateCodexDirectory
    )

    $codexDirectory = Join-Path $Root '.codex'
    if (Test-Path -LiteralPath $codexDirectory) {
        $codexItem = Get-Item -LiteralPath $codexDirectory -Force
        if (-not $codexItem.PSIsContainer) {
            Stop-Manager "Expected a directory but found a file: $codexDirectory" 4
        }
        if (($codexItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Manager "Refusing to use a reparse-point .codex directory: $codexDirectory" 4
        }
    }
    elseif ($CreateCodexDirectory) {
        New-Item -ItemType Directory -Path $codexDirectory | Out-Null
    }

    $configPath = Join-Path $codexDirectory 'config.toml'
    if (Test-Path -LiteralPath $configPath) {
        $configItem = Get-Item -LiteralPath $configPath -Force
        if (($configItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Manager "Refusing to edit a reparse-point config file: $configPath" 4
        }
    }

    $statePath = Join-Path $codexDirectory 'context-window-manager.json'
    $lockPath = Join-Path $codexDirectory 'context-window-manager.lock'
    foreach ($managedPath in @($statePath, $lockPath)) {
        if (-not (Test-Path -LiteralPath $managedPath)) { continue }
        $managedItem = Get-Item -LiteralPath $managedPath -Force
        if ($managedItem.PSIsContainer) {
            Stop-Manager "Expected a file but found a directory: $managedPath" 4
        }
        if (($managedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Manager "Refusing to use a reparse-point manager file: $managedPath" 4
        }
    }

    return [PSCustomObject]@{
        CodexDirectory = $codexDirectory
        ConfigPath = $configPath
        StatePath = $statePath
        LockPath = $lockPath
    }
}

function Assert-ModelIdentifier {
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) {
        Stop-Manager 'A non-auto profile requires the active model ID.' 2
    }
    if ($ModelId.Length -gt 128 -or $ModelId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]*$') {
        Stop-Manager 'The model ID contains unsupported characters or is longer than 128 characters.' 2
    }
}

function Get-ModelCatalog {
    if ($null -ne $script:Catalog) {
        return $script:Catalog
    }

    $catalogPath = Join-Path $PSScriptRoot 'model-capabilities.json'
    try {
        $script:Catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
    }
    catch {
        Stop-Manager "Could not read model capability catalog: $($_.Exception.Message)" 5
    }
    return $script:Catalog
}

function Get-ModelInfo {
    param([string]$ModelId)

    $catalog = Get-ModelCatalog
    $entry = $null
    if (-not [string]::IsNullOrWhiteSpace($ModelId)) {
        $entry = $catalog.models | Where-Object { $_.id -ieq $ModelId } | Select-Object -First 1
    }

    if ($null -eq $entry) {
        return [PSCustomObject]@{
            Id = $ModelId
            Known = $false
            MaxContextTokens = $null
            Source = $null
            CatalogUpdated = $catalog.updated
        }
    }

    return [PSCustomObject]@{
        Id = [string]$entry.id
        Known = $true
        MaxContextTokens = [long]$entry.maxContextTokens
        Source = [string]$entry.source
        CatalogUpdated = $catalog.updated
    }
}

function Resolve-ContextPlan {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)]$ModelInfo,
        [long]$RequestedTokens,
        [long]$RequestedCompactAt,
        [string]$RequestedScope,
        [switch]$AllowUnverified
    )

    $window = $null
    $compact = $null
    $warnings = @()

    switch ($ProfileName) {
        'auto' {
            $window = $null
            $compact = $null
        }
        'compact' {
            if (-not $ModelInfo.Known -and -not $AllowUnverified) {
                Stop-Manager "Model '$($ModelInfo.Id)' has no exact entry in the bundled dated API-model catalog. Use profile auto, pass a listed model, or explicitly use -Force." 3
            }
            $capacity = if ($ModelInfo.Known) { [long]$ModelInfo.MaxContextTokens } else { 128000L }
            $window = [Math]::Min($capacity, 128000L)
            $compact = [long][Math]::Floor($window * 0.75)
        }
        'balanced' {
            if (-not $ModelInfo.Known -and -not $AllowUnverified) {
                Stop-Manager "Model '$($ModelInfo.Id)' has no exact entry in the bundled dated API-model catalog. Use profile auto, pass a listed model, or explicitly use -Force." 3
            }
            $capacity = if ($ModelInfo.Known) { [long]$ModelInfo.MaxContextTokens } else { 400000L }
            $window = [Math]::Min($capacity, 400000L)
            $compact = [long][Math]::Floor($window * 0.80)
        }
        '1m' {
            if ((-not $ModelInfo.Known -or [long]$ModelInfo.MaxContextTokens -lt 1050000L) -and -not $AllowUnverified) {
                $knownText = if ($ModelInfo.Known) { Format-TokenCount $ModelInfo.MaxContextTokens } else { 'unknown' }
                Stop-Manager "Refusing the 1m profile: model '$($ModelInfo.Id)' has a bundled API-catalog window of $knownText tokens. Selecting 1m cannot raise the effective Codex host/account limit." 3
            }
            $window = 1050000L
            $compact = 850000L
        }
        'custom' {
            if ($RequestedTokens -le 0) {
                Stop-Manager 'The custom profile requires -Tokens with a positive value.' 2
            }
            if (-not $ModelInfo.Known -and -not $AllowUnverified) {
                Stop-Manager "Model '$($ModelInfo.Id)' has no exact entry in the bundled dated API-model catalog. Custom capacity requires a listed model or explicit -Force." 3
            }
            if ($ModelInfo.Known -and $RequestedTokens -gt [long]$ModelInfo.MaxContextTokens -and -not $AllowUnverified) {
                Stop-Manager "Requested custom window $(Format-TokenCount $RequestedTokens) exceeds the bundled API-catalog window $(Format-TokenCount $ModelInfo.MaxContextTokens)." 3
            }
            $window = $RequestedTokens
            $compact = if ($RequestedCompactAt -gt 0) { $RequestedCompactAt } else { [long][Math]::Floor($window * 0.80) }
        }
    }

    if ($RequestedCompactAt -gt 0 -and $ProfileName -ne 'custom' -and $ProfileName -ne 'auto') {
        $compact = $RequestedCompactAt
    }

    if ($null -ne $window) {
        if ([long]$window -lt 8192L) {
            Stop-Manager 'Context windows smaller than 8,192 tokens are not supported by this manager.' 2
        }
        if ($null -eq $compact -or [long]$compact -le 0 -or [long]$compact -ge [long]$window) {
            Stop-Manager 'The automatic compaction threshold must be positive and smaller than the context window.' 2
        }
    }

    if ($AllowUnverified -and $ProfileName -ne 'auto') {
        $warnings += '-Force bypassed only the local compatibility check. It cannot increase the model server-side context limit.'
    }

    return [PSCustomObject]@{
        Profile = $ProfileName
        WindowTokens = $window
        CompactAtTokens = $compact
        Scope = if ($null -eq $window) { $null } else { $RequestedScope }
        Warnings = $warnings
    }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ProjectFileSnapshotToken {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][long]$MaximumBytes
    )

    if (-not (Test-Path -LiteralPath $FilePath)) { return 'missing' }
    $item = Get-Item -LiteralPath $FilePath -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-Manager "Snapshot target is not a regular file: $FilePath" 4
    }
    if ($item.Length -gt $MaximumBytes) {
        Stop-Manager "Snapshot target exceeds the safe size limit ($MaximumBytes bytes): $FilePath" 4
    }
    return (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($FilePath)))
}

function Assert-ExpectedProjectSnapshot {
    param([Parameter(Mandatory = $true)]$Paths)

    $hasConfig = -not [string]::IsNullOrWhiteSpace($ExpectedConfigSha256)
    $hasState = -not [string]::IsNullOrWhiteSpace($ExpectedStateSha256)
    if (-not $hasConfig -and -not $hasState) { return }
    if (-not $hasConfig -or -not $hasState) {
        Stop-Manager 'Both -ExpectedConfigSha256 and -ExpectedStateSha256 are required together.' 2
    }
    foreach ($token in @($ExpectedConfigSha256, $ExpectedStateSha256)) {
        if ($token -cnotmatch '^(missing|[0-9a-f]{64})$') {
            Stop-Manager 'Expected snapshot tokens must be lowercase SHA-256 hex or missing.' 2
        }
    }

    $actualConfig = Get-ProjectFileSnapshotToken $Paths.ConfigPath 8388608L
    $actualState = Get-ProjectFileSnapshotToken $Paths.StatePath 65536L
    if ($actualConfig -cne $ExpectedConfigSha256 -or $actualState -cne $ExpectedStateSha256) {
        Stop-Manager 'Project config/state changed after the caller snapshot; no file was changed. Refresh and confirm again.' 5
    }
}

function Read-ConfigDocument {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return [PSCustomObject]@{
            Exists = $false
            Bytes = [byte[]]@()
            Hash = $null
            HasBom = $false
            Text = ''
            NewLine = "`r`n"
        }
    }

    $item = Get-Item -LiteralPath $ConfigPath -Force
    if ($item.Length -gt 8388608L) {
        Stop-Manager "config.toml exceeds the safe 8 MiB limit: $ConfigPath" 4
    }
    $bytes = [System.IO.File]::ReadAllBytes($ConfigPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $count = $bytes.Length - $offset
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $text = $utf8.GetString($bytes, $offset, $count)
    }
    catch {
        Stop-Manager "config.toml is not valid UTF-8: $ConfigPath" 4
    }

    $newLine = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    return [PSCustomObject]@{
        Exists = $true
        Bytes = $bytes
        Hash = Get-Sha256Hex $bytes
        HasBom = $hasBom
        Text = $text
        NewLine = $newLine
    }
}

function Get-ManagedBlockRange {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $beginPattern = '(?m)^' + [regex]::Escape($script:BeginMarker) + '\r?$'
    $endPattern = '(?m)^' + [regex]::Escape($script:EndMarker) + '\r?$'
    $begins = [regex]::Matches($Content, $beginPattern)
    $ends = [regex]::Matches($Content, $endPattern)

    if ($begins.Count -eq 0 -and $ends.Count -eq 0) {
        return $null
    }
    if ($begins.Count -ne 1 -or $ends.Count -ne 1 -or $ends[0].Index -lt $begins[0].Index) {
        Stop-Manager 'The context-window-manager markers are incomplete, duplicated, or out of order. No file was changed.' 4
    }

    $prefix = $Content.Substring(0, $begins[0].Index)
    foreach ($line in ($prefix -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -gt 0 -and -not $trimmed.StartsWith('#')) {
            Stop-Manager 'The managed marker appears after a TOML statement. Refusing to edit an ambiguous configuration.' 4
        }
    }

    $endExclusive = $ends[0].Index + $ends[0].Length
    if ($endExclusive -lt $Content.Length -and $Content[$endExclusive] -eq "`n") {
        $endExclusive++
    }

    return [PSCustomObject]@{
        Start = $begins[0].Index
        EndExclusive = $endExclusive
    }
}

function Get-ManagedBlockDetails {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $range = Get-ManagedBlockRange $Content
    if ($null -eq $range) { return $null }

    $block = $Content.Substring($range.Start, $range.EndExclusive - $range.Start).TrimEnd([char[]]"`r`n")
    $lines = [regex]::Split($block, '\r?\n')
    if ($lines.Count -ne 8 -or $lines[0] -cne $script:BeginMarker -or $lines[7] -cne $script:EndMarker) {
        Stop-Manager 'The managed block contains unexpected content. Review it manually; no file was changed.' 4
    }

    $profileMatch = [regex]::Match($lines[1], '^# requested_profile = "(compact|balanced|1m|custom)"$')
    $modelMatch = [regex]::Match($lines[2], '^# resolved_model = "([A-Za-z0-9][A-Za-z0-9._:/-]{0,127})"$')
    $capacityMatch = [regex]::Match($lines[3], '^# resolved_capacity = "(unknown|[0-9]+)"$')
    $windowMatch = [regex]::Match($lines[4], '^model_context_window = ([0-9]+)$')
    $compactMatch = [regex]::Match($lines[5], '^model_auto_compact_token_limit = ([0-9]+)$')
    $scopeMatch = [regex]::Match($lines[6], '^model_auto_compact_token_limit_scope = "(total|body_after_prefix)"$')
    if (-not $profileMatch.Success -or -not $modelMatch.Success -or -not $capacityMatch.Success -or
        -not $windowMatch.Success -or -not $compactMatch.Success -or -not $scopeMatch.Success) {
        Stop-Manager 'The managed block was edited or contains unsupported fields. Review it manually; no file was changed.' 4
    }

    $window = 0L
    $compact = 0L
    if (-not [long]::TryParse($windowMatch.Groups[1].Value, [ref]$window) -or
        -not [long]::TryParse($compactMatch.Groups[1].Value, [ref]$compact) -or
        $window -lt 8192L -or $compact -le 0L -or $compact -ge $window) {
        Stop-Manager 'The managed block contains invalid context or compaction values. Review it manually; no file was changed.' 4
    }

    return [PSCustomObject]@{
        Range = $range
        Profile = $profileMatch.Groups[1].Value
        Model = $modelMatch.Groups[1].Value
        ResolvedCapacity = $capacityMatch.Groups[1].Value
        WindowTokens = $window
        CompactAtTokens = $compact
        Scope = $scopeMatch.Groups[1].Value
    }
}

function Remove-ManagedBlock {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $details = Get-ManagedBlockDetails $Content
    if ($null -eq $details) {
        return [PSCustomObject]@{ Content = $Content; Found = $false }
    }

    $before = $Content.Substring(0, $details.Range.Start)
    $after = $Content.Substring($details.Range.EndExclusive)
    return [PSCustomObject]@{ Content = ($before + $after); Found = $true }
}

function Assert-NoUnmanagedContextKeys {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $escapedQuotedKeys = [regex]::Matches($Content, '(?m)^\s*(?:\[{1,2}\s*)?"((?:\\.|[^"\\])*)"\s*(?:=|\.|\])')
    foreach ($quotedKey in $escapedQuotedKeys) {
        $rawKey = $quotedKey.Groups[1].Value
        if (-not $rawKey.Contains('\')) { continue }
        try {
            $decodedKey = ('"' + $rawKey + '"') | ConvertFrom-Json
        }
        catch {
            Stop-Manager 'An escaped quoted TOML key could not be checked safely. Review it manually; no file was changed.' 4
        }
        if ($script:ManagedKeys -ccontains [string]$decodedKey) {
            $lineNumber = 1 + ([regex]::Matches($Content.Substring(0, $quotedKey.Index), "`n")).Count
            Stop-Manager "An escaped quoted key conflicts with a managed context key at line $lineNumber. Remove or migrate it explicitly before applying a profile." 4
        }
    }

    foreach ($key in $script:ManagedKeys) {
        $escaped = [regex]::Escape($key)
        $patterns = @(
            ('(?m)^\s*(?:\[{1,2}\s*)?' + $escaped + '\s*(?:=|\.|\])'),
            ('(?m)^\s*(?:\[{1,2}\s*)?"' + $escaped + '"\s*(?:=|\.|\])'),
            ("(?m)^\s*(?:\[{1,2}\s*)?'" + $escaped + "'\s*(?:=|\.|\])")
        )
        foreach ($pattern in $patterns) {
            $match = [regex]::Match($Content, $pattern)
            if (-not $match.Success) { continue }
            $lineNumber = 1 + ([regex]::Matches($Content.Substring(0, $match.Index), "`n")).Count
            Stop-Manager "A potentially conflicting key or table '$key' exists outside the managed block at line $lineNumber. Remove or migrate it explicitly before applying a profile." 4
        }
    }
}

function New-ManagedBlock {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$ModelInfo,
        [Parameter(Mandatory = $true)][string]$NewLine
    )

    $resolvedModel = if ([string]::IsNullOrWhiteSpace($ModelInfo.Id)) { 'unknown' } else { $ModelInfo.Id }
    $resolvedCapacity = if ($ModelInfo.Known) { [string]$ModelInfo.MaxContextTokens } else { 'unknown' }
    $lines = @(
        $script:BeginMarker,
        ('# requested_profile = "{0}"' -f $Plan.Profile),
        ('# resolved_model = "{0}"' -f ($resolvedModel.Replace('"', '\"'))),
        ('# resolved_capacity = "{0}"' -f $resolvedCapacity),
        ('model_context_window = {0}' -f [long]$Plan.WindowTokens),
        ('model_auto_compact_token_limit = {0}' -f [long]$Plan.CompactAtTokens),
        ('model_auto_compact_token_limit_scope = "{0}"' -f $Plan.Scope),
        $script:EndMarker
    )
    return ($lines -join $NewLine)
}

function Get-UpdatedConfigText {
    param(
        [Parameter(Mandatory = $true)]$Document,
        $Plan
    )

    $removed = Remove-ManagedBlock $Document.Text

    if ($null -eq $Plan -or $Plan.Profile -eq 'auto') {
        return [PSCustomObject]@{ Text = $removed.Content; HadBlock = $removed.Found }
    }

    Assert-NoUnmanagedContextKeys $removed.Content

    $block = New-ManagedBlock $Plan (Get-ModelInfo $Model) $Document.NewLine
    $newText = $block + $Document.NewLine
    if ($removed.Content.Length -gt 0) {
        $newText += $removed.Content
    }
    return [PSCustomObject]@{ Text = $newText; HadBlock = $removed.Found }
}

function Convert-TextToUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [bool]$WithBom
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $body = $utf8.GetBytes($Content)
    if (-not $WithBom) { return ,$body }
    $preamble = [System.Text.Encoding]::UTF8.GetPreamble()
    $result = New-Object byte[] ($preamble.Length + $body.Length)
    [Array]::Copy($preamble, 0, $result, 0, $preamble.Length)
    [Array]::Copy($body, 0, $result, $preamble.Length, $body.Length)
    return ,$result
}

function Write-AtomicConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)]$OriginalDocument,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$NewText
    )

    if ($OriginalDocument.Text -ceq $NewText) { return $false }

    $newBytes = Convert-TextToUtf8Bytes $NewText $OriginalDocument.HasBom
    $directory = [System.IO.Path]::GetDirectoryName($ConfigPath)
    $token = [guid]::NewGuid().ToString('N')
    $tempPath = Join-Path $directory ('config.toml.context-window-manager.' + $token + '.tmp')
    $backupPath = Join-Path $directory ('config.toml.context-window-manager.' + $token + '.bak')
    try {
        [System.IO.File]::WriteAllBytes($tempPath, $newBytes)
        # Recheck immediately before the atomic replacement, after the temp file
        # is ready, to keep the external-editor race window as small as possible.
        if ($OriginalDocument.Exists) {
            if (-not (Test-Path -LiteralPath $ConfigPath)) {
                Stop-Manager 'config.toml disappeared while it was being updated. No replacement was written.' 5
            }
            $currentBytes = [System.IO.File]::ReadAllBytes($ConfigPath)
            if ((Get-Sha256Hex $currentBytes) -ne $OriginalDocument.Hash) {
                Stop-Manager 'config.toml changed concurrently. Re-run the command after reviewing the other change.' 5
            }
            [System.IO.File]::Replace($tempPath, $ConfigPath, $backupPath, $true)
        }
        else {
            if (Test-Path -LiteralPath $ConfigPath) {
                Stop-Manager 'config.toml was created concurrently. Re-run the command after reviewing it.' 5
            }
            [System.IO.File]::Move($tempPath, $ConfigPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
    return $true
}

function Write-AtomicBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $directory = [System.IO.Path]::GetDirectoryName($Destination)
    $token = [guid]::NewGuid().ToString('N')
    $tempPath = Join-Path $directory ([System.IO.Path]::GetFileName($Destination) + '.' + $token + '.tmp')
    $backupPath = Join-Path $directory ([System.IO.Path]::GetFileName($Destination) + '.' + $token + '.bak')
    try {
        [System.IO.File]::WriteAllBytes($tempPath, $Bytes)
        if (Test-Path -LiteralPath $Destination) {
            [System.IO.File]::Replace($tempPath, $Destination, $backupPath, $true)
        }
        else {
            [System.IO.File]::Move($tempPath, $Destination)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-AtomicUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
    Write-AtomicBytes $Destination $bytes
}

function Restore-ConfigDocument {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)]$OriginalDocument,
        [Parameter(Mandatory = $true)][string]$ExpectedCurrentHash
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw 'Cannot roll back config.toml because it disappeared after the managed write.'
    }
    $currentBytes = [System.IO.File]::ReadAllBytes($ConfigPath)
    if ((Get-Sha256Hex $currentBytes) -cne $ExpectedCurrentHash) {
        throw 'Cannot roll back config.toml because another process changed it after the managed write.'
    }
    if ($OriginalDocument.Exists) {
        Write-AtomicBytes $ConfigPath $OriginalDocument.Bytes
    }
    else {
        Remove-Item -LiteralPath $ConfigPath -Force
    }
}

function Acquire-ManagerLock {
    param([Parameter(Mandatory = $true)][string]$LockPath)
    try {
        # OpenOrCreate lets a later run recover a lock file left by a crashed process.
        # FileShare.None still rejects a genuinely active manager.
        return [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch {
        Stop-Manager "Another context-window-manager process holds the project lock: $LockPath" 5
    }
}

function Release-ManagerLock {
    param(
        $LockStream,
        [Parameter(Mandatory = $true)][string]$LockPath
    )
    if ($null -ne $LockStream) { $LockStream.Dispose() }
    if (Test-Path -LiteralPath $LockPath) {
        # Another process may acquire the existing lock between Dispose and this
        # cleanup. On Windows its FileShare.None handle makes deletion fail; that
        # is harmless, because a future run can safely reuse a stale lock file.
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    }
}

function Read-ManagerState {
    param([Parameter(Mandatory = $true)][string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $stateText = Read-StrictUtf8File $StatePath 65536L
        $state = $stateText | ConvertFrom-Json
    }
    catch {
        Stop-Manager "The manager state file is not valid, bounded UTF-8 JSON: $StatePath" 4
    }

    $allowedStateKeys = @(
        'schemaVersion', 'profile', 'requestedModel', 'modelKnown',
        'catalogContextWindowTokens', 'windowTokens', 'compactAtTokens',
        'scope', 'updatedAt', 'hardLimitNotice'
    )
    foreach ($property in $state.PSObject.Properties) {
        if ($allowedStateKeys -cnotcontains $property.Name) {
            Stop-Manager "The manager state contains an unsupported field: $StatePath" 4
        }
    }
    if ($null -eq $state.PSObject.Properties['schemaVersion'] -or [int]$state.schemaVersion -ne 1) {
        Stop-Manager "The manager state schema is unsupported: $StatePath" 4
    }
    if ($null -eq $state.PSObject.Properties['profile']) {
        Stop-Manager "The manager state has no profile: $StatePath" 4
    }
    $profileName = [string]$state.profile
    if (@('auto', 'compact', 'balanced', '1m', 'custom') -cnotcontains $profileName) {
        Stop-Manager "The manager state contains an unsupported profile: $StatePath" 4
    }
    if ($null -ne $state.PSObject.Properties['requestedModel'] -and $null -ne $state.requestedModel) {
        $requestedModel = [string]$state.requestedModel
        if ($requestedModel.Length -gt 128 -or $requestedModel -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]*$') {
            Stop-Manager "The manager state contains an invalid model identifier: $StatePath" 4
        }
    }

    $windowValue = if ($null -ne $state.PSObject.Properties['windowTokens']) { $state.windowTokens } else { $null }
    $compactValue = if ($null -ne $state.PSObject.Properties['compactAtTokens']) { $state.compactAtTokens } else { $null }
    $scopeValue = if ($null -ne $state.PSObject.Properties['scope']) { $state.scope } else { $null }
    if ($profileName -eq 'auto') {
        if ($null -ne $windowValue -or $null -ne $compactValue -or $null -ne $scopeValue) {
            Stop-Manager "The auto-profile state contains unexpected context values: $StatePath" 4
        }
    }
    else {
        try {
            $window = [long]$windowValue
            $compact = [long]$compactValue
        }
        catch {
            Stop-Manager "The manager state contains non-integer context values: $StatePath" 4
        }
        if ($window -lt 8192L -or $compact -le 0L -or $compact -ge $window -or
            @('total', 'body_after_prefix') -cnotcontains [string]$scopeValue) {
            Stop-Manager "The manager state contains invalid context values: $StatePath" 4
        }
    }
    return $state
}

function Invoke-Status {
    $root = Resolve-ProjectRoot $ProjectRoot (Get-Location).Path
    $paths = Get-ProjectPaths $root
    if (-not [string]::IsNullOrWhiteSpace($Model)) { Assert-ModelIdentifier $Model }
    $modelInfo = Get-ModelInfo $Model
    $state = Read-ManagerState $paths.StatePath
    $document = Read-ConfigDocument $paths.ConfigPath
    $block = Get-ManagedBlockDetails $document.Text

    $warnings = @()
    if ($null -ne $block) {
        $profileName = [string]$block.Profile
        $configuredModel = [string]$block.Model
        $configuredWindow = [long]$block.WindowTokens
        $configuredCompact = [long]$block.CompactAtTokens
        $configuredScope = [string]$block.Scope
        if ($null -eq $state -or [string]$state.profile -cne $profileName -or
            $null -eq $state.requestedModel -or [string]$state.requestedModel -cne $configuredModel -or
            $null -eq $state.windowTokens -or [long]$state.windowTokens -ne $configuredWindow -or
            $null -eq $state.compactAtTokens -or [long]$state.compactAtTokens -ne $configuredCompact -or
            $null -eq $state.scope -or [string]$state.scope -cne $configuredScope) {
            $warnings += 'The state cache differs from the managed TOML block; status is reporting the TOML block as authoritative.'
        }
    }
    elseif ($null -ne $state -and [string]$state.profile -ceq 'auto') {
        $profileName = 'auto'
        $configuredModel = $null
        $configuredWindow = $null
        $configuredCompact = $null
        $configuredScope = $null
    }
    else {
        $profileName = 'not configured'
        $configuredModel = $null
        $configuredWindow = $null
        $configuredCompact = $null
        $configuredScope = $null
        if ($null -ne $state) {
            $warnings += 'A non-auto state cache exists without a managed TOML block; no configured budget is being reported.'
        }
    }
    if ($null -ne $configuredWindow -and $modelInfo.Known -and $configuredWindow -gt [long]$modelInfo.MaxContextTokens) {
        $warnings += 'Configured window exceeds the bundled dated API-model catalog entry; the effective Codex host/account limit still wins.'
    }
    if (-not $modelInfo.Known -and -not [string]::IsNullOrWhiteSpace($Model)) {
        $warnings += 'The active model is not in the bundled exact-ID catalog, so its hard capacity is unknown.'
    }

    $result = [PSCustomObject]@{
        command = 'status'
        projectRoot = $root
        configPath = $paths.ConfigPath
        profile = $profileName
        managedBlockPresent = ($null -ne $block)
        managerStatePresent = ($null -ne $state)
        configuredModel = $configuredModel
        model = $Model
        modelKnown = $modelInfo.Known
        catalogContextWindowTokens = $modelInfo.MaxContextTokens
        catalogUpdated = $modelInfo.CatalogUpdated
        configuredWindowTokens = $configuredWindow
        configuredCompactAtTokens = $configuredCompact
        configuredCompactScope = $configuredScope
        trustedProjectRequired = $true
        warnings = $warnings
    }

    if ($Json) { Write-JsonResult $result; return }
    Write-Output ('Project:            ' + $root)
    Write-Output ('Profile:            ' + $profileName)
    Write-Output ('Configured model:   ' + $(if ($null -eq $configuredModel) { 'not configured' } else { $configuredModel }))
    Write-Output ('Active model:        ' + $(if ([string]::IsNullOrWhiteSpace($Model)) { 'not supplied' } else { $Model }))
    Write-Output ('API catalog window:  ' + (Format-TokenCount $modelInfo.MaxContextTokens))
    Write-Output ('Configured window:   ' + (Format-TokenCount $configuredWindow))
    Write-Output ('Compact at:          ' + (Format-TokenCount $configuredCompact))
    Write-Output ('Compact scope:       ' + $(if ($null -eq $configuredScope) { 'not configured' } else { $configuredScope }))
    Write-Output ('Managed block:       ' + $(if ($null -ne $block) { 'present' } else { 'absent' }))
    Write-Output 'Project trust:       required; this script cannot detect the app trust state'
    foreach ($warning in $warnings) { Write-Warning $warning }
}

function Invoke-Apply {
    $root = Resolve-ProjectRoot $ProjectRoot (Get-Location).Path
    if ($Profile -ne 'auto' -or -not [string]::IsNullOrWhiteSpace($Model)) { Assert-ModelIdentifier $Model }
    $modelInfo = Get-ModelInfo $Model
    $plan = Resolve-ContextPlan $Profile $modelInfo $Tokens $CompactAt $Scope -AllowUnverified:$Force
    $previewPaths = Get-ProjectPaths $root
    $previewDocument = Read-ConfigDocument $previewPaths.ConfigPath
    $null = Get-UpdatedConfigText $previewDocument $plan

    $result = [PSCustomObject]@{
        command = 'apply'
        projectRoot = $root
        profile = $plan.Profile
        model = $Model
        modelKnown = $modelInfo.Known
        catalogContextWindowTokens = $modelInfo.MaxContextTokens
        windowTokens = $plan.WindowTokens
        compactAtTokens = $plan.CompactAtTokens
        scope = $plan.Scope
        changed = $false
        restartRequired = $true
        trustedProjectRequired = $true
        warnings = @($plan.Warnings)
    }

    if (-not $PSCmdlet.ShouldProcess($root, "Apply context profile '$Profile' to the project-scoped Codex configuration")) {
        if ($Json) { Write-JsonResult $result }
        else { Write-Output "Preview only: profile '$Profile' would target $root" }
        return
    }

    $paths = Get-ProjectPaths $root -CreateCodexDirectory
    $lock = $null
    try {
        $lock = Acquire-ManagerLock $paths.LockPath
        Assert-ExpectedProjectSnapshot $paths
        $document = Read-ConfigDocument $paths.ConfigPath
        $updated = Get-UpdatedConfigText $document $plan
        $expectedConfigHash = Get-Sha256Hex (Convert-TextToUtf8Bytes $updated.Text $document.HasBom)
        $configChanged = Write-AtomicConfig $paths.ConfigPath $document $updated.Text

        $state = [ordered]@{
            schemaVersion = 1
            profile = $plan.Profile
            requestedModel = if ($plan.Profile -eq 'auto') { $null } else { $Model }
            modelKnown = $modelInfo.Known
            catalogContextWindowTokens = $modelInfo.MaxContextTokens
            windowTokens = $plan.WindowTokens
            compactAtTokens = $plan.CompactAtTokens
            scope = $plan.Scope
            updatedAt = [DateTime]::UtcNow.ToString('o')
            hardLimitNotice = 'This dated API catalog is not live detection; configuration cannot increase the effective Codex host/account limit.'
        }
        $stateJson = $state | ConvertTo-Json -Depth 5
        try {
            Write-AtomicUtf8File $paths.StatePath ($stateJson + "`n")
        }
        catch {
            $stateFailure = $_.Exception.Message
            if ($configChanged) {
                try {
                    Restore-ConfigDocument $paths.ConfigPath $document $expectedConfigHash
                }
                catch {
                    throw "State update failed ($stateFailure), and config.toml rollback also failed: $($_.Exception.Message)"
                }
            }
            throw "State update failed; config.toml was rolled back: $stateFailure"
        }
        $result.changed = $true
    }
    finally {
        Release-ManagerLock $lock $paths.LockPath
    }

    if ($Json) { Write-JsonResult $result; return }
    Write-Output "Applied profile '$($plan.Profile)' to $($paths.ConfigPath)"
    Write-Output ('Window: ' + (Format-TokenCount $plan.WindowTokens) + '; compact at: ' + (Format-TokenCount $plan.CompactAtTokens))
    Write-Output 'This is a dated API-catalog compatibility check, not live host-capacity detection. Trust the project, then start a new Codex task (or restart the app) for reliable pickup.'
    foreach ($warning in $plan.Warnings) { Write-Warning $warning }
}

function Invoke-Reset {
    $root = Resolve-ProjectRoot $ProjectRoot (Get-Location).Path
    $previewPaths = Get-ProjectPaths $root
    $previewDocument = Read-ConfigDocument $previewPaths.ConfigPath
    $null = Get-UpdatedConfigText $previewDocument $null

    $result = [PSCustomObject]@{
        command = 'reset'
        projectRoot = $root
        configPath = $previewPaths.ConfigPath
        changed = $false
    }

    if (-not $PSCmdlet.ShouldProcess($root, 'Remove only the context-window-manager block and state')) {
        if ($Json) { Write-JsonResult $result } else { Write-Output "Preview only: manager state would be reset under $root" }
        return
    }

    if (-not (Test-Path -LiteralPath $previewPaths.CodexDirectory)) {
        if ($Json) { Write-JsonResult $result } else { Write-Output 'Nothing to reset.' }
        return
    }

    $paths = Get-ProjectPaths $root
    $lock = $null
    try {
        $lock = Acquire-ManagerLock $paths.LockPath
        Assert-ExpectedProjectSnapshot $paths
        $document = Read-ConfigDocument $paths.ConfigPath
        $updated = Get-UpdatedConfigText $document $null
        $expectedConfigHash = Get-Sha256Hex (Convert-TextToUtf8Bytes $updated.Text $document.HasBom)
        $changed = Write-AtomicConfig $paths.ConfigPath $document $updated.Text
        if (Test-Path -LiteralPath $paths.StatePath) {
            try {
                Remove-Item -LiteralPath $paths.StatePath -Force
            }
            catch {
                $stateFailure = $_.Exception.Message
                if ($changed) {
                    try {
                        Restore-ConfigDocument $paths.ConfigPath $document $expectedConfigHash
                    }
                    catch {
                        throw "State removal failed ($stateFailure), and config.toml rollback also failed: $($_.Exception.Message)"
                    }
                }
                throw "State removal failed; config.toml was rolled back: $stateFailure"
            }
            $changed = $true
        }
        $result.changed = $changed
    }
    finally {
        Release-ManagerLock $lock $paths.LockPath
    }

    if ($Json) { Write-JsonResult $result } else { Write-Output "Reset complete. Unrelated Codex configuration was preserved." }
}

function Get-ApproxTokenEstimate {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return [PSCustomObject]@{ Estimate = 0L; ByteCeiling = 8L }
    }

    $asciiWordOrSpace = [regex]::Matches($Value, '[A-Za-z0-9_\s]').Count
    $asciiAll = [regex]::Matches($Value, '[\x00-\x7F]').Count
    $asciiPunctuation = $asciiAll - $asciiWordOrSpace
    $cjk = [regex]::Matches($Value, '[\u3400-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF]').Count
    $other = [Math]::Max(0, $Value.Length - $asciiAll - $cjk)
    $estimate = [long][Math]::Ceiling(($asciiWordOrSpace / 4.0) + $asciiPunctuation + $cjk + (1.5 * $other))
    $byteCeiling = [long][Text.Encoding]::UTF8.GetByteCount($Value) + 8L
    return [PSCustomObject]@{ Estimate = $estimate; ByteCeiling = $byteCeiling }
}

function Read-StrictUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [long]$MaximumBytes
    )

    $item = Get-Item -LiteralPath $FilePath -Force
    if ($item.Length -gt $MaximumBytes) {
        throw "File exceeds the per-file limit of $MaximumBytes bytes."
    }
    $bytes = [System.IO.File]::ReadAllBytes($item.FullName)
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
        throw 'File appears to be binary (contains NUL bytes).'
    }
    $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    return $utf8.GetString($bytes, $offset, $bytes.Length - $offset)
}

function Test-TextCandidate {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)
    $extensions = @('.txt', '.md', '.markdown', '.json', '.jsonl', '.yaml', '.yml', '.toml', '.xml', '.csv', '.tsv', '.html', '.css', '.scss', '.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs', '.py', '.ps1', '.psm1', '.cs', '.java', '.go', '.rs', '.c', '.h', '.cpp', '.hpp', '.sql', '.sh', '.bat', '.cmd', '.ini', '.cfg', '.conf', '.env')
    if ($extensions -contains $File.Extension.ToLowerInvariant()) { return $true }
    return @('Dockerfile', 'Makefile', '.gitignore') -contains $File.Name
}

function Get-DirectoryTextFiles {
    param([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Directory)

    $excludedNames = @('.git', '.venv', 'node_modules', '.codex')
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push($Directory)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($child in (Get-ChildItem -LiteralPath $current.FullName -Force)) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($child.PSIsContainer) {
                if ($excludedNames -notcontains $child.Name) { $stack.Push($child) }
            }
            elseif (Test-TextCandidate $child) {
                Write-Output $child
            }
        }
    }
}

function Invoke-Estimate {
    if (-not $script:TextWasBound -and ($null -eq $Path -or $Path.Count -eq 0)) {
        Stop-Manager 'estimate requires -Text or at least one -Path.' 2
    }
    if ($MaxFileBytes -le 0) { Stop-Manager '-MaxFileBytes must be positive.' 2 }

    $rows = @()
    $errors = @()
    if ($script:TextWasBound) {
        $measure = Get-ApproxTokenEstimate $Text
        $rows += [PSCustomObject]@{ path = '<text>'; bytes = [Text.Encoding]::UTF8.GetByteCount($Text); estimate = $measure.Estimate; byteCeiling = $measure.ByteCeiling }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($inputPath in @($Path)) {
        if ([string]::IsNullOrWhiteSpace($inputPath)) { continue }
        try {
            $item = Get-Item -LiteralPath $inputPath -Force
        }
        catch {
            $errors += [PSCustomObject]@{ path = $inputPath; error = 'Path does not exist or is not readable.' }
            continue
        }

        $files = if ($item.PSIsContainer) { @(Get-DirectoryTextFiles $item) } else { @($item) }
        foreach ($file in $files) {
            if (-not $seen.Add($file.FullName)) { continue }
            try {
                $content = Read-StrictUtf8File $file.FullName $MaxFileBytes
                $measure = Get-ApproxTokenEstimate $content
                $rows += [PSCustomObject]@{ path = $file.FullName; bytes = [long]$file.Length; estimate = $measure.Estimate; byteCeiling = $measure.ByteCeiling }
            }
            catch {
                $errors += [PSCustomObject]@{ path = $file.FullName; error = $_.Exception.Message }
            }
        }
    }

    $totalEstimate = [long](($rows | Measure-Object -Property estimate -Sum).Sum)
    $totalByteCeiling = [long](($rows | Measure-Object -Property byteCeiling -Sum).Sum)
    $totalBytes = [long](($rows | Measure-Object -Property bytes -Sum).Sum)
    $result = [PSCustomObject]@{
        command = 'estimate'
        heuristic = 'ASCII word/space chars / 4 + ASCII punctuation + CJK + 1.5 * other Unicode. The byte ceiling is UTF-8 bytes + 8 per item; neither value is an official tokenizer result.'
        files = $rows
        errors = $errors
        totalBytes = $totalBytes
        estimatedTokens = $totalEstimate
        byteCeilingTokens = $totalByteCeiling
    }

    if ($Json) { Write-JsonResult $result; return }
    Write-Output ('Estimated tokens: ' + (Format-TokenCount $totalEstimate))
    Write-Output ('Byte ceiling:     ' + (Format-TokenCount $totalByteCeiling))
    Write-Output ('Text bytes:       ' + (Format-TokenCount $totalBytes))
    foreach ($row in ($rows | Sort-Object byteCeiling -Descending | Select-Object -First 10)) {
        Write-Output ('  {0,12:N0}  {1}' -f $row.byteCeiling, $row.path)
    }
    foreach ($errorRow in $errors) { Write-Warning ($errorRow.path + ': ' + $errorRow.error) }
}

function Invoke-Hook {
    $script:HookMode = $true
    try {
        $raw = [Console]::In.ReadToEnd()
        if ($raw.Length -gt 1048576) { throw 'Hook input exceeded 1 MiB.' }
        $inputObject = $raw | ConvertFrom-Json
        if ([string]$inputObject.hook_event_name -ne 'SessionStart') { return }

        $root = Resolve-ProjectRoot $null ([string]$inputObject.cwd)
        $paths = Get-ProjectPaths $root
        if (-not (Test-Path -LiteralPath $paths.StatePath)) { return }
        $state = Read-ManagerState $paths.StatePath
        $document = Read-ConfigDocument $paths.ConfigPath
        $block = Get-ManagedBlockDetails $document.Text
        if ($null -ne $block) {
            $activeProfile = [string]$block.Profile
            $activeWindow = [long]$block.WindowTokens
            $activeCompact = [long]$block.CompactAtTokens
        }
        elseif ([string]$state.profile -ceq 'auto') {
            $activeProfile = 'auto'
            $activeWindow = $null
            $activeCompact = $null
        }
        else {
            throw 'A non-auto state cache exists without a valid managed TOML block.'
        }

        $activeModel = [string]$inputObject.model
        $modelInfo = Get-ModelInfo $activeModel

        $parts = @('Context Window Manager advisory (Codex only; never a server-limit override).')
        if ($modelInfo.Known) {
            $parts += "Bundled dated API-model catalog entry: $($modelInfo.Id), documented API context window $(Format-TokenCount $modelInfo.MaxContextTokens) tokens. The effective Codex host/account limit can still be smaller."
        }
        else {
            $parts += 'The active model has no exact entry in the bundled dated API-model catalog; do not present the configured budget as a host-capacity fact.'
        }
        $parts += "Selected project profile: $activeProfile."
        if ($null -ne $activeWindow) {
            $parts += "Configured window: $(Format-TokenCount $activeWindow); compact at: $(Format-TokenCount $activeCompact)."
        }
        else {
            $parts += "This plugin's project override is absent; effective values fall through to remaining project or other Codex configuration entries and layers, then built-in model defaults."
        }
        if ($null -ne $activeWindow -and $modelInfo.Known -and $activeWindow -gt [long]$modelInfo.MaxContextTokens) {
            $parts += 'WARNING: the configured window exceeds the dated API catalog entry; the effective host limit still wins.'
        }
        $parts += 'Keep requirements, decisions, interfaces, and test evidence as anchors; load other sources selectively.'
        if ([string]$inputObject.source -eq 'compact') {
            $parts += 'This session just compacted: re-read the anchors before relying on fine details.'
        }

        $hookResult = [ordered]@{
            continue = $true
            hookSpecificOutput = [ordered]@{
                hookEventName = 'SessionStart'
                additionalContext = ($parts -join ' ')
            }
        }
        Write-JsonResult $hookResult
    }
    catch {
        # Never reflect paths, JSON values, or model IDs from project-controlled
        # hook input into developer context on an error path.
        Write-JsonResult ([ordered]@{ continue = $true; systemMessage = 'Context Window Manager hook skipped: project state or hook input was invalid.' })
    }
    finally {
        $script:HookMode = $false
    }
}

function Show-Help {
    @'
Context Window Manager (Windows PowerShell 5.1, no third-party modules)

  context-window.ps1 status   [-ProjectRoot PATH] [-Model ID] [-Json]
  context-window.ps1 apply    -Profile auto|compact|balanced|1m|custom
                              [-Model ID] [-Tokens N] [-CompactAt N]
                              [-Scope total|body_after_prefix] [-Force] [-WhatIf] [-Json]
  context-window.ps1 reset    [-ProjectRoot PATH] [-WhatIf] [-Json]
  context-window.ps1 estimate (-Text STRING | -Path PATHS) [-MaxFileBytes N] [-Json]
  context-window.ps1 hook     # SessionStart hook; JSON is read from stdin

The script edits only its marked block in <project>/.codex/config.toml.
It cannot increase the selected model's server-side context capacity.
'@
}

if ($Command -eq 'hook') {
    Invoke-Hook
    exit 0
}

try {
    switch ($Command) {
        'status' { Invoke-Status }
        'apply' { Invoke-Apply }
        'reset' { Invoke-Reset }
        'estimate' { Invoke-Estimate }
        'help' { Show-Help }
    }
}
catch {
    [Console]::Error.WriteLine('Context Window Manager failed: ' + $_.Exception.Message)
    exit 5
}
