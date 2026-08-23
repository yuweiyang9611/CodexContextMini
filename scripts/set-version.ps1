[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$pattern = '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<pre>(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?$'

function Compare-ReleaseVersion {
    param([string]$Left, [string]$Right)
    $leftMatch=[regex]::Match($Left,$pattern)
    $rightMatch=[regex]::Match($Right,$pattern)
    foreach($name in @('major','minor','patch')){
        $leftNumber=[long]$leftMatch.Groups[$name].Value
        $rightNumber=[long]$rightMatch.Groups[$name].Value
        if($leftNumber -lt $rightNumber){ return -1 }
        if($leftNumber -gt $rightNumber){ return 1 }
    }
    $leftPre=$leftMatch.Groups['pre'].Value
    $rightPre=$rightMatch.Groups['pre'].Value
    if([string]::IsNullOrEmpty($leftPre) -and [string]::IsNullOrEmpty($rightPre)){ return 0 }
    if([string]::IsNullOrEmpty($leftPre)){ return 1 }
    if([string]::IsNullOrEmpty($rightPre)){ return -1 }
    $leftParts=$leftPre.Split('.')
    $rightParts=$rightPre.Split('.')
    for($index=0;$index -lt [Math]::Min($leftParts.Length,$rightParts.Length);$index++){
        $leftNumeric=[long]0; $rightNumeric=[long]0
        $isLeftNumeric=[long]::TryParse($leftParts[$index],[ref]$leftNumeric)
        $isRightNumeric=[long]::TryParse($rightParts[$index],[ref]$rightNumeric)
        if($isLeftNumeric -and $isRightNumeric){
            if($leftNumeric -lt $rightNumeric){ return -1 }
            if($leftNumeric -gt $rightNumeric){ return 1 }
            continue
        }
        if($isLeftNumeric){ return -1 }
        if($isRightNumeric){ return 1 }
        $comparison=[string]::CompareOrdinal($leftParts[$index],$rightParts[$index])
        if($comparison -lt 0){ return -1 }
        if($comparison -gt 0){ return 1 }
    }
    if($leftParts.Length -lt $rightParts.Length){ return -1 }
    if($leftParts.Length -gt $rightParts.Length){ return 1 }
    return 0
}

$normalized=$Version.Trim()
if($normalized.StartsWith('v',[StringComparison]::OrdinalIgnoreCase)){ $normalized=$normalized.Substring(1) }
if($normalized -cnotmatch $pattern){ throw 'Version must be release SemVer such as 0.2.1 or 0.3.0-beta.1.' }
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$versionPath=Join-Path $root 'VERSION'
$current=[IO.File]::ReadAllText($versionPath).Trim()
if($current -cnotmatch $pattern){ throw "Current VERSION is invalid: $current" }
if($current -ceq $normalized){ Write-Output "Release version is already $normalized."; return }
if((Compare-ReleaseVersion $normalized $current) -le 0){ throw "New release version $normalized must be greater than current version $current." }
if(-not $PSCmdlet.ShouldProcess($versionPath,"Change release version from $current to $normalized")){
    Write-Output "Preview: release version would change from $current to $normalized."
    return
}
[IO.File]::WriteAllText($versionPath,$normalized+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
Write-Output "Release version set to $normalized. Commit VERSION; CI will release v$normalized after main passes."