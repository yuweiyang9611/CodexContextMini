[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolver=Join-Path $root 'scripts\resolve-version-change.ps1'
$setter=Join-Path $root 'scripts\set-version.ps1'
$utf8=New-Object Text.UTF8Encoding($false)
$passed=0

function Invoke-Git([string]$Repo,[Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments){
    $saved=$ErrorActionPreference
    try{ $ErrorActionPreference='SilentlyContinue'; $output=@(& git -C $Repo @Arguments 2>&1); $code=$LASTEXITCODE }
    finally{ $ErrorActionPreference=$saved }
    if($code -ne 0){ throw "git $($Arguments -join ' ') failed." }
    return $output
}
function Read-Plan([string]$Repo,[string]$Before,[string]$Current){
    $output=@(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $resolver -RepositoryRoot $Repo -BeforeCommit $Before -CurrentCommit $Current -Json)
    if($LASTEXITCODE -ne 0){ throw 'resolve-version-change.ps1 failed.' }
    return (($output -join [Environment]::NewLine)|ConvertFrom-Json)
}
function Write-Version([string]$Repo,[string]$Version){ [IO.File]::WriteAllText((Join-Path $Repo 'VERSION'),$Version+"`n",$utf8) }
function Assert([bool]$Condition,[string]$Message){ if(-not $Condition){ throw $Message } }

$temp=Join-Path ([IO.Path]::GetTempPath()) ('context-mini-release-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temp
try{
    $null=Invoke-Git $temp init -b main
    $null=Invoke-Git $temp config user.name release-test
    $null=Invoke-Git $temp config user.email '123456+release-test@users.noreply.github.com'
    Write-Version $temp '0.2.0'
    $null=Invoke-Git $temp add -- VERSION
    $null=Invoke-Git $temp commit -m baseline
    $baseline=([string](Invoke-Git $temp rev-parse HEAD|Select-Object -Last 1)).Trim()

    [IO.File]::WriteAllText((Join-Path $temp 'change.txt'),"ordinary change`n",$utf8)
    $null=Invoke-Git $temp add -- change.txt
    $null=Invoke-Git $temp commit -m change
    $ordinary=([string](Invoke-Git $temp rev-parse HEAD|Select-Object -Last 1)).Trim()
    $plan=Read-Plan $temp $baseline $ordinary
    Assert (-not [bool]$plan.changed) 'Ordinary code changes must not release.'
    Write-Output 'PASS ordinary code changes do not release'; $passed++

    $scriptDir=Join-Path $temp 'scripts'; $null=New-Item -ItemType Directory -Path $scriptDir
    Copy-Item -LiteralPath $setter -Destination (Join-Path $scriptDir 'set-version.ps1')
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'set-version.ps1') 'v0.2.1' | Out-Null
    if($LASTEXITCODE -ne 0){ throw 'set-version.ps1 failed.' }
    Assert (([IO.File]::ReadAllText((Join-Path $temp 'VERSION')).Trim()) -ceq '0.2.1') 'VERSION was not updated.'
    $null=Invoke-Git $temp add -- VERSION
    $null=Invoke-Git $temp commit -m bump
    $bump=([string](Invoke-Git $temp rev-parse HEAD|Select-Object -Last 1)).Trim()
    $plan=Read-Plan $temp $ordinary $bump
    Assert ([bool]$plan.changed) 'A manual VERSION change must release.'
    Assert ([string]$plan.currentReleaseVersion -ceq '0.2.1') 'Unexpected current version.'
    Assert ([string]$plan.tag -ceq 'v0.2.1') 'Unexpected tag.'
    Write-Output 'PASS manual VERSION change triggers one release'; $passed++

    [IO.File]::WriteAllText((Join-Path $temp 'fix.txt'),"CI fix`n",$utf8)
    $null=Invoke-Git $temp add -- fix.txt
    $null=Invoke-Git $temp commit -m fix
    $fix=([string](Invoke-Git $temp rev-parse HEAD|Select-Object -Last 1)).Trim()
    $plan=Read-Plan $temp $bump $fix
    Assert ([bool]$plan.changed) 'The same bumped VERSION must remain eligible after a CI-fix commit.'
    Assert ([string]$plan.versionCommit -ceq $bump) 'Version introduction commit drifted.'
    Write-Output 'PASS failed version CI can be repaired without another bump'; $passed++
    $plan=Read-Plan $temp ('f'*40) $fix
    Assert (-not [bool]$plan.changed) 'Unavailable previous commit must fail closed.'
    Write-Output 'PASS unavailable previous commit establishes no-release baseline'; $passed++

    $noVersion=Join-Path $temp 'no-version'; $null=New-Item -ItemType Directory -Path $noVersion
    $null=Invoke-Git $noVersion init -b main; $null=Invoke-Git $noVersion config user.name release-test; $null=Invoke-Git $noVersion config user.email '123456+release-test@users.noreply.github.com'
    [IO.File]::WriteAllText((Join-Path $noVersion 'README.md'),"baseline`n",$utf8); $null=Invoke-Git $noVersion add -- README.md; $null=Invoke-Git $noVersion commit -m baseline
    $before=([string](Invoke-Git $noVersion rev-parse HEAD|Select-Object -Last 1)).Trim()
    Write-Version $noVersion '1.0.0'; $null=Invoke-Git $noVersion add -- VERSION; $null=Invoke-Git $noVersion commit -m version
    $after=([string](Invoke-Git $noVersion rev-parse HEAD|Select-Object -Last 1)).Trim()
    $plan=Read-Plan $noVersion $before $after
    Assert (-not [bool]$plan.changed) 'First VERSION file must establish a baseline.'
    Write-Output 'PASS first VERSION file establishes no-release baseline'; $passed++

    $savedPreference=$ErrorActionPreference
    try{ $ErrorActionPreference='SilentlyContinue'; $invalid=@(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'set-version.ps1') '1.02.3' -WhatIf 2>&1); $invalidCode=$LASTEXITCODE }
    finally{ $ErrorActionPreference=$savedPreference }
    Assert ($invalidCode -ne 0) 'Invalid SemVer was accepted.'
    Write-Output 'PASS invalid SemVer is rejected'; $passed++
    $savedPreference=$ErrorActionPreference
    try{ $ErrorActionPreference='SilentlyContinue'; $downgrade=@(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'set-version.ps1') '0.2.0' -WhatIf 2>&1); $downgradeCode=$LASTEXITCODE }
    finally{ $ErrorActionPreference=$savedPreference }
    Assert ($downgradeCode -ne 0) 'Version downgrade was accepted.'
    Write-Output 'PASS version downgrade is rejected'; $passed++
}
finally{ if(Test-Path -LiteralPath $temp){ Remove-Item -LiteralPath $temp -Recurse -Force } }
Write-Output "RESULT passed=$passed failed=0"
