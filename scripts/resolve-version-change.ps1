[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string]$BeforeCommit,
    [string]$CurrentCommit = 'HEAD',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Join-Path $PSScriptRoot '..' }
$root = [IO.Path]::GetFullPath((Get-Item -LiteralPath $RepositoryRoot -Force).FullName)
$semverPattern = '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<pre>(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?$'

function Invoke-GitExpected {
    param([string[]]$Arguments,[int[]]$Allowed=@(0))
    $saved=$ErrorActionPreference
    try{ $ErrorActionPreference='SilentlyContinue'; $output=@(& git -C $root @Arguments 2>$null); $code=$LASTEXITCODE }
    finally{ $ErrorActionPreference=$saved }
    if($Allowed -notcontains $code){ throw "Git command failed with exit code $code." }
    return [PSCustomObject]@{Code=$code;Output=$output}
}
function Resolve-Commit {
    param([string]$Commit,[switch]$AllowMissing)
    $result=Invoke-GitExpected @('rev-parse','--verify',($Commit+'^{commit}')) $(if($AllowMissing){@(0,1,128)}else{@(0)})
    if($result.Code -ne 0){ return $null }
    return ([string]($result.Output|Select-Object -Last 1)).Trim()
}
function Read-VersionAtCommit {
    param([string]$Commit,[switch]$AllowMissing)
    $result=Invoke-GitExpected @('show',($Commit+':VERSION')) $(if($AllowMissing){@(0,1,128)}else{@(0)})
    if($result.Code -ne 0){ return $null }
    $version=(($result.Output -join [Environment]::NewLine).Trim())
    if($version -cnotmatch $semverPattern){ throw "VERSION at commit $Commit is not release SemVer: $version" }
    return $version
}
function Compare-ReleaseVersion {
    param([string]$Left,[string]$Right)
    $leftMatch=[regex]::Match($Left,$semverPattern)
    $rightMatch=[regex]::Match($Right,$semverPattern)
    if(-not $leftMatch.Success -or -not $rightMatch.Success){ throw 'Release version comparison requires valid SemVer.' }
    foreach($name in @('major','minor','patch')){
        $leftNumber=[bigint]::Parse($leftMatch.Groups[$name].Value)
        $rightNumber=[bigint]::Parse($rightMatch.Groups[$name].Value)
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
        $leftNumeric=$leftParts[$index] -cmatch '^(?:0|[1-9]\d*)$'
        $rightNumeric=$rightParts[$index] -cmatch '^(?:0|[1-9]\d*)$'
        if($leftNumeric -and $rightNumeric){
            $leftNumber=[bigint]::Parse($leftParts[$index])
            $rightNumber=[bigint]::Parse($rightParts[$index])
            if($leftNumber -lt $rightNumber){ return -1 }
            if($leftNumber -gt $rightNumber){ return 1 }
            continue
        }
        if($leftNumeric){ return -1 }
        if($rightNumeric){ return 1 }
        $comparison=[string]::CompareOrdinal($leftParts[$index],$rightParts[$index])
        if($comparison -lt 0){ return -1 }
        if($comparison -gt 0){ return 1 }
    }
    if($leftParts.Length -lt $rightParts.Length){ return -1 }
    if($leftParts.Length -gt $rightParts.Length){ return 1 }
    return 0
}

$currentSha=Resolve-Commit $CurrentCommit
$currentVersion=Read-VersionAtCommit $currentSha
$beforeValue=$BeforeCommit.Trim()
$beforeSha=$null
$eligible=$false
$reason=$null
$versionCommit=$null
$previousVersion=$null

if([string]::IsNullOrWhiteSpace($beforeValue) -or $beforeValue -cmatch '^0+$'){
    $reason='No previous commit was supplied; the current version is recorded as a baseline.'
}
else{
    $beforeSha=Resolve-Commit $beforeValue -AllowMissing
    if($null -eq $beforeSha){ $reason='The previous commit is unavailable; release is skipped because history cannot be proven.' }
    else{
        $history=Invoke-GitExpected @('rev-list',$currentSha,'--','VERSION')
        foreach($candidate in @($history.Output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -cmatch '^[0-9a-f]{40,64}$' })){
            $candidateVersion=Read-VersionAtCommit $candidate -AllowMissing
            if($null -eq $candidateVersion){ continue }
            if($null -eq $versionCommit){
                if($candidateVersion -cne $currentVersion){ throw 'VERSION history does not match the checked-out value.' }
                $versionCommit=$candidate
                continue
            }
            if($candidateVersion -cne $currentVersion){ $previousVersion=$candidateVersion; break }
        }
        if($null -eq $versionCommit){ throw 'Unable to identify the commit that introduced the current VERSION.' }
        if(($null -ne $previousVersion) -and ((Compare-ReleaseVersion $currentVersion $previousVersion) -le 0)){
            throw "Current VERSION $currentVersion must be greater than previous release version $previousVersion."
        }
        $eligible=$null -ne $previousVersion
        $reason=if($eligible){ "Current version $currentVersion was introduced after $previousVersion and remains eligible until released." }else{ "Version $currentVersion is the repository baseline." }
    }
}

$result=[PSCustomObject]@{
    changed=$eligible
    reason=$reason
    previousCommit=$beforeSha
    previousReleaseVersion=$previousVersion
    versionCommit=$versionCommit
    currentCommit=$currentSha
    currentReleaseVersion=$currentVersion
    tag="v$currentVersion"
}
if($Json){ $result|ConvertTo-Json -Compress }else{ $result }
