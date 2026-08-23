[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$appPath = Join-Path $root 'src\ContextMini\App.xaml'
$windowPath = Join-Path $root 'src\ContextMini\MainWindow.xaml'
$lightPath = Join-Path $root 'src\ContextMini\Themes\Light.xaml'
$darkPath = Join-Path $root 'src\ContextMini\Themes\Dark.xaml'

foreach ($path in @($appPath, $windowPath, $lightPath, $darkPath)) {
    $document = New-Object System.Xml.XmlDocument
    $document.PreserveWhitespace = $true
    $document.Load($path)
}

function Get-ResourceKeys([string]$path) {
    $content = [IO.File]::ReadAllText($path)
    return @(
        [regex]::Matches($content, 'x:Key="([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object
    )
}

$lightKeys = @(Get-ResourceKeys $lightPath)
$darkKeys = @(Get-ResourceKeys $darkPath)
$keyDifference = @(
    $lightKeys | Where-Object { $darkKeys -cnotcontains $_ } | ForEach-Object { "Light only: $_" }
    $darkKeys | Where-Object { $lightKeys -cnotcontains $_ } | ForEach-Object { "Dark only: $_" }
)
if ($keyDifference.Count -ne 0) {
    throw "Light and Dark palette resource keys differ: $($keyDifference | Out-String)"
}
if ($lightKeys.Count -eq 0) { throw 'Theme palettes contain no resources.' }

$window = [IO.File]::ReadAllText($windowPath)
$usedKeys = @(
    [regex]::Matches($window, 'DynamicResource\s+([^}\s]+)') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object
)
$missingKeys = @($usedKeys | Where-Object { $lightKeys -cnotcontains $_ })
if ($missingKeys.Count -ne 0) {
    throw "MainWindow uses missing theme resources: $($missingKeys -join ', ')"
}

$hardCodedColors = [regex]::Matches(
    $window,
    '#[0-9A-Fa-f]{6,8}|(?:Background|Foreground|BorderBrush)="(?:White|Black)"')
if ($hardCodedColors.Count -ne 0) {
    throw 'MainWindow.xaml must use dynamic palette resources instead of hard-coded colors.'
}

$requiredSelectorFragments = @(
    'x:Name="SystemAppearanceButton"',
    'x:Name="LightAppearanceButton"',
    'x:Name="DarkAppearanceButton"',
    'Tag="{x:Static core:AppearancePreference.System}"',
    'Tag="{x:Static core:AppearancePreference.Light}"',
    'Tag="{x:Static core:AppearancePreference.Dark}"',
    'AutomationProperties.Name=',
    'Click="Appearance_Click"'
)
foreach ($fragment in $requiredSelectorFragments) {
    if (-not $window.Contains($fragment)) { throw "Appearance selector is missing: $fragment" }
}

$app = [IO.File]::ReadAllText($appPath)
if (-not $app.Contains('Source="Themes/Light.xaml"')) {
    throw 'App.xaml must provide a light design-time/startup fallback palette.'
}

function Get-PaletteColors([string]$path) {
    $colors = @{}
    $content = [IO.File]::ReadAllText($path)
    foreach ($match in [regex]::Matches($content, 'x:Key="([^"]+)"\s+Color="(#[0-9A-Fa-f]{6})"')) {
        $colors[$match.Groups[1].Value] = $match.Groups[2].Value
    }
    return $colors
}

function Get-RelativeLuminance([string]$color) {
    $channels = @(
        [Convert]::ToInt32($color.Substring(1, 2), 16),
        [Convert]::ToInt32($color.Substring(3, 2), 16),
        [Convert]::ToInt32($color.Substring(5, 2), 16)
    )
    $linear = @($channels | ForEach-Object {
        $channel = $_ / 255.0
        if ($channel -le 0.04045) { $channel / 12.92 }
        else { [Math]::Pow(($channel + 0.055) / 1.055, 2.4) }
    })
    return 0.2126 * $linear[0] + 0.7152 * $linear[1] + 0.0722 * $linear[2]
}

function Get-ContrastRatio([string]$first, [string]$second) {
    $firstLuminance = Get-RelativeLuminance $first
    $secondLuminance = Get-RelativeLuminance $second
    if ($firstLuminance -lt $secondLuminance) {
        $swap = $firstLuminance
        $firstLuminance = $secondLuminance
        $secondLuminance = $swap
    }
    return ($firstLuminance + 0.05) / ($secondLuminance + 0.05)
}

$textPairs = @(
    @('HeaderTextBrush', 'HeaderBackgroundBrush'),
    @('HeaderSecondaryTextBrush', 'HeaderBackgroundBrush'),
    @('HeaderControlTextBrush', 'HeaderControlBackgroundBrush'),
    @('HeaderControlHoverTextBrush', 'HeaderControlHoverBackgroundBrush'),
    @('HeaderSelectedTextBrush', 'HeaderSelectedBackgroundBrush'),
    @('PrimaryTextBrush', 'SurfaceBackgroundBrush'),
    @('SecondaryTextBrush', 'SurfaceBackgroundBrush'),
    @('TertiaryTextBrush', 'WindowBackgroundBrush'),
    @('TertiaryTextBrush', 'FooterBackgroundBrush'),
    @('AccentTextBrush', 'AlternateSurfaceBrush'),
    @('ControlTextBrush', 'ControlBackgroundBrush'),
    @('ControlHoverTextBrush', 'ControlHoverBackgroundBrush'),
    @('ControlHoverTextBrush', 'ControlPressedBackgroundBrush'),
    @('OnPrimaryActionTextBrush', 'PrimaryActionBackgroundBrush'),
    @('OnPrimaryActionTextBrush', 'PrimaryActionHoverBackgroundBrush'),
    @('OnPrimaryActionTextBrush', 'PrimaryActionPressedBackgroundBrush'),
    @('SelectedControlTextBrush', 'SelectedControlBackgroundBrush'),
    @('WarningTextBrush', 'WarningBackgroundBrush')
)
$focusBackgrounds = @(
    'ControlBackgroundBrush',
    'SelectedControlBackgroundBrush',
    'HeaderSelectedBackgroundBrush'
)
foreach ($paletteSpec in @(@('Light', $lightPath), @('Dark', $darkPath))) {
    $paletteName = $paletteSpec[0]
    $colors = Get-PaletteColors $paletteSpec[1]
    foreach ($pair in $textPairs) {
        $ratio = Get-ContrastRatio $colors[$pair[0]] $colors[$pair[1]]
        if ($ratio -lt 4.5) {
            throw "$paletteName text contrast is below 4.5:1 for $($pair[0]) / $($pair[1]): $ratio"
        }
    }
    foreach ($background in $focusBackgrounds) {
        $ratio = Get-ContrastRatio $colors['FocusBorderBrush'] $colors[$background]
        if ($ratio -lt 3.0) {
            throw "$paletteName focus contrast is below 3:1 for ${background}: $ratio"
        }
    }
}

Write-Output "Appearance XAML tests passed: $($lightKeys.Count) palette keys, $($usedKeys.Count) dynamic references, contrast thresholds met."
