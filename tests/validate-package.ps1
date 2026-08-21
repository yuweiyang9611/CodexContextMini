[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ExpectedReleaseVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$failures = New-Object 'System.Collections.Generic.List[string]'

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { Add-Failure $Message }
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Failure "Missing JSON file: $Path"
        return $null
    }
    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ($text.Contains('[TODO:')) { Add-Failure "Placeholder remains in $Path" }
        return ($text | ConvertFrom-Json)
    }
    catch {
        Add-Failure "Invalid JSON in ${Path}: $($_.Exception.Message)"
        return $null
    }
}

function Assert-HttpsUrl {
    param($Value, [string]$Label)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return }
    $uri = $null
    $valid = [System.Uri]::TryCreate([string]$Value, [System.UriKind]::Absolute, [ref]$uri)
    Assert-True ($valid -and $null -ne $uri -and $uri.Scheme -ceq 'https') "$Label must be an absolute HTTPS URL."
}

function Resolve-ContainedPath {
    param([string]$BasePath, [string]$RelativePath, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        -not $RelativePath.StartsWith('./', [System.StringComparison]::Ordinal) -or
        $RelativePath.Contains('\') -or
        [System.IO.Path]::IsPathRooted($RelativePath)) {
        Add-Failure "$Label must be a ./-prefixed forward-slash relative path."
        return $null
    }

    $localPart = $RelativePath.Substring(2).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $resolved = [System.IO.Path]::GetFullPath((Join-Path $BasePath $localPart))
    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $prefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure "$Label escapes its allowed root."
        return $null
    }
    return $resolved
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..'
}
$rootItem = Get-Item -LiteralPath $RepositoryRoot -Force
$root = [System.IO.Path]::GetFullPath($rootItem.FullName)
$pluginRoot = Join-Path $root 'plugins\context-window-manager'
$manifestPath = Join-Path $pluginRoot '.codex-plugin\plugin.json'
$marketplacePath = Join-Path $root '.agents\plugins\marketplace.json'
$mcpPath = Join-Path $pluginRoot '.mcp.json'
$hooksPath = Join-Path $pluginRoot 'hooks\hooks.json'
$catalogPath = Join-Path $pluginRoot 'scripts\model-capabilities.json'

$manifest = Read-JsonFile $manifestPath
$marketplace = Read-JsonFile $marketplacePath
$mcp = Read-JsonFile $mcpPath
$null = Read-JsonFile $hooksPath
$null = Read-JsonFile $catalogPath

$releaseVersion = $null
if ($null -ne $manifest) {
    $allowedFields = @(
        'id', 'name', 'version', 'description', 'author', 'homepage', 'repository',
        'license', 'keywords', 'skills', 'apps', 'mcpServers', 'interface'
    )
    foreach ($property in $manifest.PSObject.Properties.Name) {
        Assert-True ($allowedFields -ccontains $property) "Unsupported plugin manifest field: $property"
    }

    $name = [string](Get-PropertyValue $manifest 'name')
    $version = [string](Get-PropertyValue $manifest 'version')
    $description = [string](Get-PropertyValue $manifest 'description')
    $author = Get-PropertyValue $manifest 'author'
    $interface = Get-PropertyValue $manifest 'interface'

    Assert-True ($name -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -and $name.Length -le 64) 'Manifest name must be <=64 characters of lower-case hyphen-case.'
    Assert-True ($name -ceq (Split-Path -Leaf $pluginRoot)) 'Manifest name must match the plugin directory name.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($description)) 'Manifest description is required.'

    $semverPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
    Assert-True ($version -cmatch $semverPattern) 'Manifest version must be strict SemVer.'
    if ($version -cmatch $semverPattern) {
        $releaseVersion = ($version -split '\+', 2)[0]
        if (-not [string]::IsNullOrWhiteSpace($ExpectedReleaseVersion)) {
            $expected = $ExpectedReleaseVersion.Trim()
            if ($expected.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) { $expected = $expected.Substring(1) }
            Assert-True ($releaseVersion -ceq $expected) "Release version '$releaseVersion' does not match expected '$expected'."
        }
    }

    $authorName = [string](Get-PropertyValue $author 'name')
    Assert-True (-not [string]::IsNullOrWhiteSpace($authorName)) 'Manifest author.name is required.'
    Assert-True ($authorName -cne 'Local developer') 'Manifest author must identify the public maintainer.'
    Assert-HttpsUrl (Get-PropertyValue $author 'url') 'author.url'
    Assert-HttpsUrl (Get-PropertyValue $manifest 'homepage') 'homepage'
    Assert-HttpsUrl (Get-PropertyValue $manifest 'repository') 'repository'
    Assert-True ([string](Get-PropertyValue $manifest 'license') -ceq 'MIT') 'Manifest license must be MIT.'

    foreach ($field in @('displayName', 'shortDescription', 'longDescription', 'developerName', 'category')) {
        Assert-True (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $interface $field))) "interface.$field is required."
    }
    $capabilities = Get-PropertyValue $interface 'capabilities'
    $capabilityList = @($capabilities)
    Assert-True ($null -ne $capabilities -and $capabilityList.Count -gt 0) 'interface.capabilities must be a non-empty array.'
    foreach ($capability in $capabilityList) {
        Assert-True ($capability -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$capability)) 'Each capability must be a non-empty string.'
    }
    $prompts = Get-PropertyValue $interface 'defaultPrompt'
    $promptList = @($prompts)
    Assert-True ($null -ne $prompts -and $promptList.Count -ge 1 -and $promptList.Count -le 3) 'interface.defaultPrompt must contain 1-3 prompts.'
    foreach ($prompt in $promptList) {
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$prompt) -and ([string]$prompt).Length -le 128) 'Each default prompt must be non-empty and <=128 characters.'
    }
    Assert-HttpsUrl (Get-PropertyValue $interface 'websiteURL') 'interface.websiteURL'

    $skillsPath = Resolve-ContainedPath $pluginRoot ([string](Get-PropertyValue $manifest 'skills')) 'skills'
    if ($null -ne $skillsPath) { Assert-True (Test-Path -LiteralPath $skillsPath -PathType Container) 'Manifest skills directory does not exist.' }
    $manifestMcpPath = Resolve-ContainedPath $pluginRoot ([string](Get-PropertyValue $manifest 'mcpServers')) 'mcpServers'
    if ($null -ne $manifestMcpPath) { Assert-True (Test-Path -LiteralPath $manifestMcpPath -PathType Leaf) 'Manifest MCP config does not exist.' }

    if ($null -ne $releaseVersion) {
        $serverText = [System.IO.File]::ReadAllText((Join-Path $pluginRoot 'mcp\server.mjs'))
        $uiText = [System.IO.File]::ReadAllText((Join-Path $pluginRoot 'ui\context-window-control.html'))
        Assert-True ($serverText.Contains('const SERVER_VERSION = "' + $releaseVersion + '";')) 'MCP server version must match the manifest release version.'
        Assert-True ($uiText.Contains('appInfo: { name: "context-window-manager-widget", version: "' + $releaseVersion + '" }')) 'Widget version must match the manifest release version.'
    }
}

if ($null -ne $marketplace -and $null -ne $manifest) {
    Assert-True (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $marketplace 'name'))) 'Marketplace name is required.'
    $entries = Get-PropertyValue $marketplace 'plugins'
    $entryList = @($entries)
    Assert-True ($null -ne $entries -and $entryList.Count -gt 0) 'Marketplace plugins must be a non-empty array.'
    $matching = @($entryList | Where-Object { [string](Get-PropertyValue $_ 'name') -ceq [string](Get-PropertyValue $manifest 'name') })
    Assert-True ($matching.Count -eq 1) 'Marketplace must contain exactly one matching plugin entry.'
    if ($matching.Count -eq 1) {
        $entry = $matching[0]
        $source = Get-PropertyValue $entry 'source'
        $policy = Get-PropertyValue $entry 'policy'
        Assert-True ([string](Get-PropertyValue $source 'source') -ceq 'local') 'Marketplace source.source must be local.'
        $sourcePath = Resolve-ContainedPath $root ([string](Get-PropertyValue $source 'path')) 'marketplace source.path'
        if ($null -ne $sourcePath) {
            Assert-True ([System.IO.Path]::GetFullPath($sourcePath) -ceq [System.IO.Path]::GetFullPath($pluginRoot)) 'Marketplace source.path must resolve to the plugin root.'
        }
        Assert-True (@('NOT_AVAILABLE', 'AVAILABLE', 'INSTALLED_BY_DEFAULT') -ccontains [string](Get-PropertyValue $policy 'installation')) 'Marketplace installation policy is invalid.'
        Assert-True (@('ON_INSTALL', 'ON_USE') -ccontains [string](Get-PropertyValue $policy 'authentication')) 'Marketplace authentication policy is invalid.'
        Assert-True ([string](Get-PropertyValue $entry 'category') -ceq [string](Get-PropertyValue (Get-PropertyValue $manifest 'interface') 'category')) 'Marketplace and manifest categories must match.'
    }
}

if ($null -ne $mcp) {
    $servers = Get-PropertyValue $mcp 'mcpServers'
    Assert-True ($null -ne $servers -and @($servers.PSObject.Properties).Count -gt 0) '.mcp.json must define at least one MCP server.'
    Assert-True (Test-Path -LiteralPath (Join-Path $pluginRoot 'scripts\launch-context-window-mcp.cmd') -PathType Leaf) 'MCP launcher is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $pluginRoot 'mcp\server.mjs') -PathType Leaf) 'MCP server is missing.'
}

$licensePath = Join-Path $root 'LICENSE'
$readmePath = Join-Path $root 'README.md'
Assert-True (Test-Path -LiteralPath $licensePath -PathType Leaf) 'Root LICENSE is missing.'
Assert-True (Test-Path -LiteralPath $readmePath -PathType Leaf) 'Root README.md is missing.'
if (Test-Path -LiteralPath $licensePath -PathType Leaf) {
    $licenseText = [System.IO.File]::ReadAllText($licensePath)
    Assert-True ($licenseText.Contains('MIT License') -and $licenseText.Contains('Permission is hereby granted') -and $licenseText.Contains('THE SOFTWARE IS PROVIDED "AS IS"')) 'LICENSE does not contain the expected MIT terms.'
}
if (Test-Path -LiteralPath $readmePath -PathType Leaf) {
    Assert-True ([System.IO.File]::ReadAllText($readmePath).Contains('[MIT](LICENSE)')) 'README must link to the MIT license.'
}

$forbiddenExtensions = @('.exe', '.dll', '.pdb', '.zip')
$bundledBinaries = @(Get-ChildItem -LiteralPath $pluginRoot -Recurse -Force -File | Where-Object { $forbiddenExtensions -ccontains $_.Extension })
Assert-True ($bundledBinaries.Count -eq 0) 'Plugin source must not contain compiled binaries or ZIP archives.'

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { [Console]::Error.WriteLine("ERROR: $failure") }
    [Console]::Error.WriteLine("Package validation failed with $($failures.Count) error(s).")
    exit 1
}

Write-Output "Package validation passed. Manifest=$([string](Get-PropertyValue $manifest 'version')); Release=$releaseVersion"
