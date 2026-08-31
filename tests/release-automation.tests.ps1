[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolver = Join-Path $root 'scripts\resolve-version-change.ps1'
$setter = Join-Path $root 'scripts\set-version.ps1'
$publisher = Join-Path $root 'scripts\publish.ps1'
$releaseBuilder = Join-Path $root 'scripts\build-release.ps1'
$releaseModule = Join-Path $root 'scripts\ReleaseAutomation.psm1'
$workflow = Join-Path $root '.github\workflows\ci-release.yml'
$actionlintValidator = Join-Path $root 'scripts\validate-github-actions.ps1'
$readme = Join-Path $root 'README.md'
$utf8 = New-Object Text.UTF8Encoding($false)
$passed = 0
Import-Module $releaseModule -Force

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Run([string]$Name, [scriptblock]$Test) {
    & $Test
    $script:passed++
    Write-Output "PASS $Name"
}

function Assert-Throws([scriptblock]$Action, [string]$Message, [string]$ExpectedText = '') {
    $thrown = $false
    try { & $Action | Out-Null }
    catch {
        $thrown = $true
        if (-not [string]::IsNullOrWhiteSpace($ExpectedText)) {
            Assert ($_.Exception.Message.Contains($ExpectedText)) "$Message Unexpected error: $($_.Exception.Message)"
        }
    }
    Assert $thrown $Message
}

function Invoke-Git([string]$Repo, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments) {
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $output = @(& git -C $Repo @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $saved }
    if ($code -ne 0) { throw "git $($Arguments -join ' ') failed." }
    return $output
}

function Read-Plan([string]$Repo, [string]$Before, [string]$Current) {
    $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $resolver -RepositoryRoot $Repo -BeforeCommit $Before -CurrentCommit $Current -Json)
    if ($LASTEXITCODE -ne 0) { throw 'resolve-version-change.ps1 failed.' }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Write-Utf8([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Write-Version([string]$Repo, [string]$Version) {
    Write-Utf8 -Path (Join-Path $Repo 'VERSION') -Text ($Version + "`n")
}

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
    $null = New-Item -ItemType Directory -Path $Destination
    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse
}

function Add-ZipFixtureEntry([string]$ArchivePath, [string]$EntryName) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($ArchivePath, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $archive.CreateEntry($EntryName)
        $stream = $entry.Open()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes("unsafe fixture`n")
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally { $stream.Dispose() }
    }
    finally { $archive.Dispose() }
}

function New-FakePublish([string]$Path, [switch]$SelfContained) {
    $null = New-Item -ItemType Directory -Path $Path
    foreach ($name in @('ContextMini.exe','ContextMini.dll','ContextMini.runtimeconfig.json','LICENSE')) {
        Write-Utf8 -Path (Join-Path $Path $name) -Text ("fixture:$name`n")
    }
    $libraries = [ordered]@{ 'ContextMini/1.2.3' = [ordered]@{} }
    if ($SelfContained) {
        $libraries['runtimepack.Microsoft.WindowsDesktop.App.Runtime.win-x64/10.0.11'] = [ordered]@{}
        $libraries['runtimepack.Microsoft.NETCore.App.Runtime.win-x64/10.0.11'] = [ordered]@{}
        foreach ($runtimeName in @('coreclr.dll','hostfxr.dll','hostpolicy.dll')) {
            Write-Utf8 -Path (Join-Path $Path $runtimeName) -Text ("fixture:$runtimeName`n")
        }
    }
    $deps = [ordered]@{ libraries = $libraries }
    Write-Utf8 -Path (Join-Path $Path 'ContextMini.deps.json') -Text (($deps | ConvertTo-Json -Depth 5) + "`n")
}

function New-FakePackageRoot([string]$Path) {
    $packs = @(
        [PSCustomObject]@{ Id = 'Microsoft.NETCore.App.Runtime.win-x64'; Version = '10.0.11' },
        [PSCustomObject]@{ Id = 'Microsoft.WindowsDesktop.App.Runtime.win-x64'; Version = '10.0.11' }
    )
    foreach ($pack in $packs) {
        $package = Join-Path (Join-Path $Path $pack.Id.ToLowerInvariant()) $pack.Version
        Write-Utf8 -Path (Join-Path $package 'LICENSE.txt') -Text ("License for $($pack.Id) $($pack.Version)`n")
        Write-Utf8 -Path (Join-Path $package 'THIRD-PARTY-NOTICES.txt') -Text "Shared full third-party notice text.`r`nSecond line.`r`n"
    }
    $unused = Join-Path (Join-Path $Path 'microsoft.aspnetcore.app.runtime.win-x64') '10.0.11'
    Write-Utf8 -Path (Join-Path $unused 'LICENSE.txt') -Text "Unused package license`n"
    Write-Utf8 -Path (Join-Path $unused 'THIRD-PARTY-NOTICES.txt') -Text "Unused package notice`n"
}

function New-PublishedRelease([string]$AssetDirectory, [object]$Layout, [bool]$Immutable) {
    $assets = @(
        $Layout.AssetNames | ForEach-Object {
            [ordered]@{
                name = [string]$_
                digest = 'sha256:' + (Get-ContextMiniSha256 -Path (Join-Path $AssetDirectory $_))
            }
        }
    )
    return (([ordered]@{ isDraft = $false; isImmutable = $Immutable; assets = $assets } | ConvertTo-Json -Depth 5) | ConvertFrom-Json)
}

function New-StateRelease([bool]$Draft, [string]$TargetSha, [string[]]$AssetNames, [bool]$Prerelease = $false) {
    $assets = @($AssetNames | ForEach-Object { [ordered]@{ name = $_ } })
    return (([ordered]@{
        isDraft = $Draft
        isPrerelease = $Prerelease
        name = 'Context Mini 1.2.3'
        tagName = 'v1.2.3'
        targetCommitish = $TargetSha
        assets = $assets
    } | ConvertTo-Json -Depth 5) | ConvertFrom-Json)
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('context-mini-release-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
try {
    $versionRepo = Join-Path $temp 'version-repo'
    $null = New-Item -ItemType Directory -Path $versionRepo
    $null = Invoke-Git $versionRepo init -b main
    $null = Invoke-Git $versionRepo config user.name release-test
    $null = Invoke-Git $versionRepo config user.email '123456+release-test@users.noreply.github.com'
    Write-Version $versionRepo '0.2.0'
    $null = Invoke-Git $versionRepo add -- VERSION
    $null = Invoke-Git $versionRepo commit -m baseline
    $baseline = ([string](Invoke-Git $versionRepo rev-parse HEAD | Select-Object -Last 1)).Trim()

    Write-Utf8 -Path (Join-Path $versionRepo 'change.txt') -Text "ordinary change`n"
    $null = Invoke-Git $versionRepo add -- change.txt
    $null = Invoke-Git $versionRepo commit -m change
    $ordinary = ([string](Invoke-Git $versionRepo rev-parse HEAD | Select-Object -Last 1)).Trim()
    Run 'ordinary code changes do not release' {
        $plan = Read-Plan $versionRepo $baseline $ordinary
        Assert (-not [bool]$plan.changed) 'Ordinary code changes must not release.'
    }

    $scriptDir = Join-Path $versionRepo 'scripts'
    $null = New-Item -ItemType Directory -Path $scriptDir
    Copy-Item -LiteralPath $setter -Destination (Join-Path $scriptDir 'set-version.ps1')
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'set-version.ps1') 'v0.2.1' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'set-version.ps1 failed.' }
    $null = Invoke-Git $versionRepo add -- VERSION
    $null = Invoke-Git $versionRepo commit -m bump
    $bump = ([string](Invoke-Git $versionRepo rev-parse HEAD | Select-Object -Last 1)).Trim()
    Run 'manual VERSION change triggers one release' {
        $plan = Read-Plan $versionRepo $ordinary $bump
        Assert ([bool]$plan.changed) 'A manual VERSION change must release.'
        Assert ([string]$plan.currentReleaseVersion -ceq '0.2.1') 'Unexpected current version.'
        Assert ([string]$plan.tag -ceq 'v0.2.1') 'Unexpected tag.'
    }

    Write-Utf8 -Path (Join-Path $versionRepo 'fix.txt') -Text "CI fix`n"
    $null = Invoke-Git $versionRepo add -- fix.txt
    $null = Invoke-Git $versionRepo commit -m fix
    $fix = ([string](Invoke-Git $versionRepo rev-parse HEAD | Select-Object -Last 1)).Trim()
    Run 'failed version CI can be repaired without another bump' {
        $plan = Read-Plan $versionRepo $bump $fix
        Assert ([bool]$plan.changed) 'The same bumped VERSION must remain eligible after a CI-fix commit.'
        Assert ([string]$plan.versionCommit -ceq $bump) 'Version introduction commit drifted.'
    }
    Run 'unavailable previous commit establishes no-release baseline' {
        $plan = Read-Plan $versionRepo ('f' * 40) $fix
        Assert (-not [bool]$plan.changed) 'Unavailable previous commit must fail closed.'
    }

    $downgradeRepo = Join-Path $temp 'downgrade-repo'
    $null = New-Item -ItemType Directory -Path $downgradeRepo
    $null = Invoke-Git $downgradeRepo init -b main
    $null = Invoke-Git $downgradeRepo config user.name release-test
    $null = Invoke-Git $downgradeRepo config user.email '123456+release-test@users.noreply.github.com'
    Write-Version $downgradeRepo '0.2.1'
    $null = Invoke-Git $downgradeRepo add -- VERSION
    $null = Invoke-Git $downgradeRepo commit -m baseline
    $beforeDowngrade = ([string](Invoke-Git $downgradeRepo rev-parse HEAD | Select-Object -Last 1)).Trim()
    Write-Version $downgradeRepo '0.2.0'
    $null = Invoke-Git $downgradeRepo add -- VERSION
    $null = Invoke-Git $downgradeRepo commit -m direct-downgrade
    $directDowngrade = ([string](Invoke-Git $downgradeRepo rev-parse HEAD | Select-Object -Last 1)).Trim()
    Run 'direct VERSION downgrade fails closed in the CI resolver' {
        Assert-Throws {
            & $resolver -RepositoryRoot $downgradeRepo -BeforeCommit $beforeDowngrade -CurrentCommit $directDowngrade -Json
        } 'A direct VERSION downgrade passed the CI release resolver.' 'must be greater than previous release version'
    }

    $noVersion = Join-Path $temp 'no-version'
    $null = New-Item -ItemType Directory -Path $noVersion
    $null = Invoke-Git $noVersion init -b main
    $null = Invoke-Git $noVersion config user.name release-test
    $null = Invoke-Git $noVersion config user.email '123456+release-test@users.noreply.github.com'
    Write-Utf8 -Path (Join-Path $noVersion 'README.md') -Text "baseline`n"
    $null = Invoke-Git $noVersion add -- README.md
    $null = Invoke-Git $noVersion commit -m baseline
    $before = ([string](Invoke-Git $noVersion rev-parse HEAD | Select-Object -Last 1)).Trim()
    Write-Version $noVersion '1.0.0'
    $null = Invoke-Git $noVersion add -- VERSION
    $null = Invoke-Git $noVersion commit -m version
    $after = ([string](Invoke-Git $noVersion rev-parse HEAD | Select-Object -Last 1)).Trim()
    Run 'first VERSION file establishes no-release baseline' {
        $plan = Read-Plan $noVersion $before $after
        Assert (-not [bool]$plan.changed) 'First VERSION file must establish a baseline.'
    }

    Run 'invalid SemVer is rejected' {
        $saved = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'SilentlyContinue'
            $null = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'set-version.ps1') '1.02.3' -WhatIf 2>&1)
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $saved }
        Assert ($code -ne 0) 'Invalid SemVer was accepted.'
    }
    Run 'version downgrade is rejected' {
        $saved = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'SilentlyContinue'
            $null = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'set-version.ps1') '0.2.0' -WhatIf 2>&1)
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $saved }
        Assert ($code -ne 0) 'Version downgrade was accepted.'
    }

    $packageRoot = Join-Path $temp 'packages'
    New-FakePackageRoot -Path $packageRoot
    $selfOne = Join-Path $temp 'self-one'
    $selfTwo = Join-Path $temp 'self-two'
    $framework = Join-Path $temp 'framework'
    New-FakePublish -Path $selfOne -SelfContained
    New-FakePublish -Path $selfTwo -SelfContained
    New-FakePublish -Path $framework
    $null = Add-ContextMiniRuntimePackNotices -PublishDirectory $selfOne -PackageRoot $packageRoot
    $null = Add-ContextMiniRuntimePackNotices -PublishDirectory $selfTwo -PackageRoot $packageRoot

    Run 'self-contained notices index only actual runtime packs and deduplicate full text' {
        $manifest = [IO.File]::ReadAllText((Join-Path $selfOne 'RUNTIME-PACKS.json')) | ConvertFrom-Json
        $packages = @($manifest.packages)
        Assert ($packages.Count -eq 2) 'Runtime manifest does not list exactly the two deps runtime packs.'
        Assert (@($packages | Where-Object { $_.id -like '*AspNetCore*' }).Count -eq 0) 'Unused restored runtime pack leaked into the manifest.'
        Assert (@($manifest.combinedThirdPartyNotices.sourceNoticeSha256).Count -eq 1) 'Identical notice content was not deduplicated by SHA-256.'
        $combined = [IO.File]::ReadAllText((Join-Path $selfOne 'THIRD-PARTY-NOTICES.txt'))
        Assert ($combined.Contains('Package: Microsoft.NETCore.App.Runtime.win-x64/10.0.11')) 'Combined notices omit the actual Core runtime pack.'
        Assert ($combined.Contains('Package: Microsoft.WindowsDesktop.App.Runtime.win-x64/10.0.11')) 'Combined notices omit the actual Desktop runtime pack.'
        Assert (-not $combined.Contains('AspNetCore')) 'Combined notices mention a runtime pack not shipped by the app.'
        Assert ([regex]::Matches($combined, 'Notice-SHA256: [0-9a-f]{64}').Count -eq 1) 'Combined notices repeat identical notice bodies.'
        Assert ([regex]::Matches($combined, [regex]::Escape('Shared full third-party notice text.')).Count -eq 1) 'Combined notices do not contain exactly one complete shared notice body.'
    }

    $selfZipOne = Join-Path $temp 'self-one.zip'
    $selfZipTwo = Join-Path $temp 'self-two.zip'
    $frameworkZip = Join-Path $temp 'framework.zip'
    New-ContextMiniDeterministicZip -SourceDirectory $selfOne -ArchivePath $selfZipOne
    New-ContextMiniDeterministicZip -SourceDirectory $selfTwo -ArchivePath $selfZipTwo
    New-ContextMiniDeterministicZip -SourceDirectory $framework -ArchivePath $frameworkZip

    Run 'framework and self-contained manifests enforce distinct runtime contents' {
        Assert-ContextMiniArchiveManifest -ArchivePath $frameworkZip -Kind FrameworkDependent
        Assert-ContextMiniArchiveManifest -ArchivePath $selfZipOne -Kind SelfContained
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($frameworkZip)
        try {
            $names = @($archive.Entries | ForEach-Object FullName)
            Assert ($names -cnotcontains 'THIRD-PARTY-NOTICES.txt') 'Framework-dependent ZIP includes self-contained third-party notices.'
            Assert ($names -cnotcontains 'RUNTIME-PACKS.json') 'Framework-dependent ZIP includes a self-contained runtime manifest.'
        }
        finally { $archive.Dispose() }
    }

    Run 'framework-dependent manifest rejects hidden runtime-pack dependencies' {
        $frameworkWithPack = Join-Path $temp 'framework-with-pack'
        Copy-DirectoryContents -Source $framework -Destination $frameworkWithPack
        $depsPath = Join-Path $frameworkWithPack 'ContextMini.deps.json'
        $deps = [IO.File]::ReadAllText($depsPath) | ConvertFrom-Json
        $deps.libraries | Add-Member -NotePropertyName 'runtimepack.Hidden.Runtime.win-x64/10.0.11' -NotePropertyValue ([PSCustomObject]@{})
        Write-Utf8 -Path $depsPath -Text (($deps | ConvertTo-Json -Depth 8) + "`n")
        $badZip = Join-Path $temp 'framework-with-pack.zip'
        New-ContextMiniDeterministicZip -SourceDirectory $frameworkWithPack -ArchivePath $badZip
        Assert-Throws { Assert-ContextMiniArchiveManifest -ArchivePath $badZip -Kind FrameworkDependent } 'Framework ZIP with hidden runtime pack passed.' 'unexpectedly identifies runtimepack'
    }

    Run 'release manifest rejects Windows-unsafe ZIP entry names' {
        foreach ($unsafeName in @('docs/payload.txt:zone','docs/NUL.txt','docs/name. ')) {
            $unsafeZip = Join-Path $temp ("unsafe-" + [guid]::NewGuid().ToString('N') + '.zip')
            Copy-Item -LiteralPath $frameworkZip -Destination $unsafeZip
            Add-ZipFixtureEntry -ArchivePath $unsafeZip -EntryName $unsafeName
            Assert-Throws { Assert-ContextMiniArchiveManifest -ArchivePath $unsafeZip -Kind FrameworkDependent } "Windows-unsafe ZIP entry passed: $unsafeName" 'Windows-unsafe entry name'
        }
    }

    Run 'release ZIP output is reproducible with ordinal entries and fixed timestamps' {
        Assert ((Get-ContextMiniSha256 -Path $selfZipOne) -ceq (Get-ContextMiniSha256 -Path $selfZipTwo)) 'Equivalent self-contained publish trees produce different ZIP hashes.'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($selfZipOne)
        try {
            $names = [string[]]@($archive.Entries | ForEach-Object FullName)
            $sorted = [string[]]@($names)
            [Array]::Sort($sorted, [StringComparer]::Ordinal)
            Assert (-not (Compare-Object $sorted $names -CaseSensitive -SyncWindow 0)) 'ZIP entries are not in ordinal order.'
            foreach ($entry in $archive.Entries) {
                Assert ($entry.LastWriteTime.DateTime -eq [datetime]'1980-01-01T00:00:00') "ZIP entry timestamp is not fixed: $($entry.FullName)"
            }
        }
        finally { $archive.Dispose() }
    }

    Run 'self-contained manifest rejects a missing root combined notice' {
        $missingRoot = Join-Path $temp 'missing-root'
        Copy-DirectoryContents -Source $selfOne -Destination $missingRoot
        Remove-Item -LiteralPath (Join-Path $missingRoot 'THIRD-PARTY-NOTICES.txt') -Force
        $badZip = Join-Path $temp 'missing-root.zip'
        New-ContextMiniDeterministicZip -SourceDirectory $missingRoot -ArchivePath $badZip
        Assert-Throws { Assert-ContextMiniArchiveManifest -ArchivePath $badZip -Kind SelfContained } 'Self-contained ZIP without root notices passed.' 'missing THIRD-PARTY-NOTICES.txt'
    }

    Run 'runtime manifest cannot omit or invent deps runtime packs' {
        $missingPack = Join-Path $temp 'missing-pack'
        Copy-DirectoryContents -Source $selfOne -Destination $missingPack
        $manifestPath = Join-Path $missingPack 'RUNTIME-PACKS.json'
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        $manifest.packages = @($manifest.packages | Select-Object -First 1)
        Write-Utf8 -Path $manifestPath -Text (($manifest | ConvertTo-Json -Depth 8) + "`n")
        $missingPackZip = Join-Path $temp 'missing-pack.zip'
        New-ContextMiniDeterministicZip -SourceDirectory $missingPack -ArchivePath $missingPackZip
        Assert-Throws { Assert-ContextMiniArchiveManifest -ArchivePath $missingPackZip -Kind SelfContained } 'Runtime manifest omitted an actual deps pack.' 'omits runtime package'

        $extraDeps = Join-Path $temp 'extra-deps'
        Copy-DirectoryContents -Source $selfOne -Destination $extraDeps
        $depsPath = Join-Path $extraDeps 'ContextMini.deps.json'
        $deps = [IO.File]::ReadAllText($depsPath) | ConvertFrom-Json
        $deps.libraries | Add-Member -NotePropertyName 'runtimepack.Extra.Runtime.win-x64/10.0.11' -NotePropertyValue ([PSCustomObject]@{})
        Write-Utf8 -Path $depsPath -Text (($deps | ConvertTo-Json -Depth 8) + "`n")
        $extraDepsZip = Join-Path $temp 'extra-deps.zip'
        New-ContextMiniDeterministicZip -SourceDirectory $extraDeps -ArchivePath $extraDepsZip
        Assert-Throws { Assert-ContextMiniArchiveManifest -ArchivePath $extraDepsZip -Kind SelfContained } 'Runtime manifest accepted an unindexed deps pack.' 'omits runtime package'
    }

    $layout = Get-ContextMiniReleaseLayout -Version '1.2.3'
    $assetDirectory = Join-Path $temp 'assets'
    $null = New-Item -ItemType Directory -Path $assetDirectory
    Copy-Item -LiteralPath $frameworkZip -Destination (Join-Path $assetDirectory $layout.FrameworkArchive)
    Copy-Item -LiteralPath $selfZipOne -Destination (Join-Path $assetDirectory $layout.SelfContainedArchive)
    $checksumLines = @(
        $layout.ZipNames | ForEach-Object { "$(Get-ContextMiniSha256 -Path (Join-Path $assetDirectory $_))  $_" }
    )
    Write-Utf8 -Path (Join-Path $assetDirectory $layout.Checksums) -Text (($checksumLines -join "`n") + "`n")
    $trustedDirectory = Join-Path $temp 'trusted-assets'
    Copy-DirectoryContents -Source $assetDirectory -Destination $trustedDirectory

    Run 'fresh and same-SHA draft states are publishable or recoverable without an existing tag' {
        $sourceSha = 'a' * 40
        $fresh = Resolve-ContextMiniReleaseState -Version '1.2.3' -Tag 'v1.2.3' -SourceSha $sourceSha -TagCommit $null -Release $null
        Assert ($fresh.Publish -and $fresh.CompareTested -and -not $fresh.Recover) 'Fresh no-tag state is incorrect.'
        $draft = New-StateRelease -Draft $true -TargetSha $sourceSha -AssetNames @($layout.Checksums)
        $recover = Resolve-ContextMiniReleaseState -Version '1.2.3' -Tag 'v1.2.3' -SourceSha $sourceSha -TagCommit $null -Release $draft
        Assert ($recover.Recover -and $recover.CompareTested -and -not $recover.Publish) 'Same-SHA partial draft is not recoverable.'
        Assert-Throws { Resolve-ContextMiniReleaseState -Version '1.2.3' -Tag 'v1.2.3' -SourceSha $sourceSha -TagCommit $null -Release $draft -RequireCompleteDraft } 'Incomplete draft passed the pre-publish recheck.' 'Draft release is missing'
    }

    Run 'published ancestor state accepts retry without comparing a later tested build' {
        $release = New-StateRelease -Draft $false -TargetSha ('a' * 40) -AssetNames $layout.AssetNames
        $state = Resolve-ContextMiniReleaseState -Version '1.2.3' -Tag 'v1.2.3' -SourceSha ('b' * 40) -TagCommit ('a' * 40) -Release $release -TagIsAncestor $true
        Assert (-not $state.Publish -and -not $state.Recover -and -not $state.CompareTested) 'Published ancestor retry state is incorrect.'
    }

    Run 'cross-SHA drafts are rejected' {
        $draft = New-StateRelease -Draft $true -TargetSha ('c' * 40) -AssetNames @()
        Assert-Throws { Resolve-ContextMiniReleaseState -Version '1.2.3' -Tag 'v1.2.3' -SourceSha ('a' * 40) -TagCommit $null -Release $draft } 'Cross-SHA draft was accepted.' 'different commit'
    }

    Run 'release state accepts only exact SHA-1 or SHA-256 object IDs' {
        foreach ($invalidSha in @(('a' * 39), ('a' * 41), ('a' * 63), ('a' * 65))) {
            Assert-Throws { Resolve-ContextMiniReleaseState -Version '1.2.3' -Tag 'v1.2.3' -SourceSha $invalidSha -TagCommit $null -Release $null } "Invalid object ID length $($invalidSha.Length) was accepted." 'Source SHA is invalid'
        }
        $state = Resolve-ContextMiniReleaseState -Version '1.2.3' -Tag 'v1.2.3' -SourceSha ('a' * 64) -TagCommit $null -Release $null
        Assert ($state.Publish) 'A valid 64-character SHA-256 object ID was rejected.'
    }

    Run 'release state rejects unexpected or missing published assets' {
        $unexpected = New-StateRelease -Draft $true -TargetSha ('a' * 40) -AssetNames @('untrusted.exe')
        Assert-Throws { Resolve-ContextMiniReleaseState -Version '1.2.3' -Tag 'v1.2.3' -SourceSha ('a' * 40) -TagCommit $null -Release $unexpected } 'Unexpected draft asset was accepted.' 'unexpected assets'
        $missing = New-StateRelease -Draft $false -TargetSha ('a' * 40) -AssetNames @($layout.Checksums)
        Assert-Throws { Resolve-ContextMiniReleaseState -Version '1.2.3' -Tag 'v1.2.3' -SourceSha ('b' * 40) -TagCommit ('a' * 40) -Release $missing -TagIsAncestor $true } 'Incomplete published release was accepted.' 'missing'
    }

    Run 'mutable and immutable release metadata both require exact SHA-256 assets' {
        $mutable = New-PublishedRelease -AssetDirectory $assetDirectory -Layout $layout -Immutable $false
        $mutableResult = Assert-ContextMiniPublishedReleaseAssets -Release $mutable -DownloadedDirectory $assetDirectory -Version '1.2.3'
        Assert (-not $mutableResult.IsImmutable) 'Mutable release was reported immutable.'
        $immutable = New-PublishedRelease -AssetDirectory $assetDirectory -Layout $layout -Immutable $true
        $immutableResult = Assert-ContextMiniPublishedReleaseAssets -Release $immutable -DownloadedDirectory $assetDirectory -Version '1.2.3' -TrustedDirectory $trustedDirectory -CompareTested
        Assert ($immutableResult.IsImmutable) 'Immutable release was reported mutable.'
        foreach ($assetName in $layout.AssetNames) {
            Assert ([IO.Path]::GetFullPath($immutableResult.VerificationPaths[$assetName]) -ceq [IO.Path]::GetFullPath((Join-Path $trustedDirectory $assetName))) 'Immutable attestation path is not the validated trusted artifact.'
        }
        $draft = New-PublishedRelease -AssetDirectory $assetDirectory -Layout $layout -Immutable $false
        $draft.isDraft = $true
        $null = Assert-ContextMiniReleaseAssetDigests -Release $draft -AssetDirectory $trustedDirectory -Version '1.2.3'
        $draft.assets[0].digest = 'sha256:' + ('0' * 64)
        Assert-Throws { Assert-ContextMiniReleaseAssetDigests -Release $draft -AssetDirectory $trustedDirectory -Version '1.2.3' } 'A same-name draft asset with different bytes passed pre-publication validation.' 'digest mismatch'
    }

    Run 'published asset validation rejects digest, unexpected, and missing asset failures' {
        $badDigest = New-PublishedRelease -AssetDirectory $assetDirectory -Layout $layout -Immutable $true
        $badDigest.assets[0].digest = 'sha256:' + ('0' * 64)
        Assert-Throws { Assert-ContextMiniPublishedReleaseAssets -Release $badDigest -DownloadedDirectory $assetDirectory -Version '1.2.3' } 'Bad GitHub digest was accepted.' 'digest mismatch'

        $missingRemote = New-PublishedRelease -AssetDirectory $assetDirectory -Layout $layout -Immutable $false
        $missingRemote.assets = @($missingRemote.assets | Select-Object -Skip 1)
        Assert-Throws { Assert-ContextMiniPublishedReleaseAssets -Release $missingRemote -DownloadedDirectory $assetDirectory -Version '1.2.3' } 'Missing remote asset was accepted.' 'Unexpected Release assets'

        $unexpectedRemote = New-PublishedRelease -AssetDirectory $assetDirectory -Layout $layout -Immutable $false
        $unexpectedRemote.assets += [PSCustomObject]@{ name = 'unexpected.bin'; digest = 'sha256:' + ('0' * 64) }
        Assert-Throws { Assert-ContextMiniPublishedReleaseAssets -Release $unexpectedRemote -DownloadedDirectory $assetDirectory -Version '1.2.3' } 'Unexpected remote asset was accepted.' 'Unexpected Release assets'
    }

    Run 'local release asset validation rejects missing and unexpected files' {
        $missingLocal = Join-Path $temp 'missing-local'
        Copy-DirectoryContents -Source $assetDirectory -Destination $missingLocal
        Remove-Item -LiteralPath (Join-Path $missingLocal $layout.Checksums) -Force
        Assert-Throws { Assert-ContextMiniReleaseAssetDirectory -AssetDirectory $missingLocal -Version '1.2.3' } 'Missing local release asset was accepted.' 'Unexpected release assets'
        $unexpectedLocal = Join-Path $temp 'unexpected-local'
        Copy-DirectoryContents -Source $assetDirectory -Destination $unexpectedLocal
        Write-Utf8 -Path (Join-Path $unexpectedLocal 'unexpected.bin') -Text "unexpected`n"
        Assert-Throws { Assert-ContextMiniReleaseAssetDirectory -AssetDirectory $unexpectedLocal -Version '1.2.3' } 'Unexpected local release asset was accepted.' 'Unexpected release assets'
    }

    Run 'Latest selection uses highest stable SemVer regardless of API order' {
        $releases = @(
            ([PSCustomObject]@{ tagName = 'v2.1.9'; isDraft = $false; isPrerelease = $false }),
            ([PSCustomObject]@{ tagName = 'v10.0.0-beta.1'; isDraft = $false; isPrerelease = $true }),
            ([PSCustomObject]@{ tagName = 'v1.99.99'; isDraft = $false; isPrerelease = $false }),
            ([PSCustomObject]@{ tagName = 'v10.0.0'; isDraft = $true; isPrerelease = $false }),
            ([PSCustomObject]@{ tagName = 'v3.0.0'; isDraft = $false; isPrerelease = $false })
        )
        Assert ((Select-ContextMiniHighestStableReleaseTag -Releases $releases) -ceq 'v3.0.0') 'Highest stable SemVer selection is incorrect.'
    }
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

Run 'publisher supports framework-dependent and self-contained win-x64 outputs' {
    $text = [IO.File]::ReadAllText($publisher)
    Assert ($text.Contains('[switch]$SelfContained')) 'publish.ps1 has no self-contained mode.'
    Assert ($text.Contains('--runtime win-x64 --self-contained true')) 'Self-contained publish does not explicitly target win-x64.'
    Assert ($text.Contains('--self-contained false')) 'Framework-dependent publish mode is missing.'
    Assert ($text.Contains('--source https://api.nuget.org/v3/index.json')) 'Runtime packs do not use the official restore source.'
}

Run 'release builder uses validated deterministic staging and one atomic output move' {
    $text = [IO.File]::ReadAllText($releaseBuilder)
    Assert ($text.Contains('Add-ContextMiniRuntimePackNotices')) 'Self-contained packaging does not collect runtime-pack notices.'
    Assert ($text.Contains('New-ContextMiniDeterministicZip')) 'Release archives do not use the deterministic writer.'
    Assert ($text.Contains('Assert-ContextMiniReleaseAssetDirectory')) 'Complete staged assets are not verified.'
    Assert ($text.Contains('[IO.Directory]::Move($assetStage, $output)')) 'Validated assets are not committed with one directory move.'
    Assert (-not $text.Contains('Compress-Archive')) 'Release ZIPs use nondeterministic Compress-Archive metadata.'
}

Run 'all release scripts parse under Windows PowerShell 5.1' {
    foreach ($relativePath in @(
        'scripts\ReleaseAutomation.psm1',
        'scripts\build-release.ps1',
        'scripts\resolve-ci-release.ps1',
        'scripts\get-release-state.ps1',
        'scripts\verify-release-assets.ps1',
        'scripts\publish-github-release.ps1',
        'scripts\verify-github-release.ps1',
        'scripts\set-latest-github-release.ps1',
        'scripts\validate-github-actions.ps1'
    )) {
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relativePath), [ref]$tokens, [ref]$errors)
        Assert ($errors.Count -eq 0) "$relativePath does not parse under Windows PowerShell 5.1: $($errors -join '; ')"
    }
}

Run 'CI orchestrates reusable release scripts and validates every workflow with pinned actionlint' {
    $workflowText = [IO.File]::ReadAllText($workflow)
    foreach ($scriptName in @('resolve-ci-release.ps1','get-release-state.ps1','verify-release-assets.ps1','publish-github-release.ps1','verify-github-release.ps1','set-latest-github-release.ps1','validate-github-actions.ps1')) {
        Assert ($workflowText.Contains($scriptName)) "CI does not invoke $scriptName."
    }
    Assert (([regex]::Matches($workflowText, 'scripts\\build-release\.ps1')).Count -eq 1) 'CI must build release assets exactly once.'
    Assert (-not $workflowText.Contains('gh release view')) 'Release state logic remains inline in CI.'
    Assert (-not $workflowText.Contains('Get-FileHash')) 'Asset digest logic remains inline in CI.'
    Assert ($workflowText.Contains('group: release-${{ github.repository }}-main')) 'Release jobs are not serialized across commits.'
    Assert ($workflowText.Contains('queue: max')) 'Release concurrency can discard pending version jobs.'
    Assert ($workflowText.Contains('actions/upload-artifact@')) 'CI does not upload tested release assets.'
    Assert ($workflowText.Contains('actions/download-artifact@')) 'Release job does not download tested release assets.'
    $stateScriptText = [IO.File]::ReadAllText((Join-Path $root 'scripts\get-release-state.ps1'))
    Assert ($stateScriptText.Contains('gh repo view $Repository --json nameWithOwner')) 'Release-not-found handling does not first prove repository access.'
    $publishScriptText = [IO.File]::ReadAllText((Join-Path $root 'scripts\publish-github-release.ps1'))
    Assert ([regex]::Matches($publishScriptText, 'Assert-RecoverableDraft -RequireComplete').Count -eq 2) 'Create/recover does not revalidate a complete matching draft before publication.'
    Assert ([regex]::IsMatch($publishScriptText, 'Assert-RecoverableDraft\s*\r?\n\$uploadArguments')) 'Draft recovery does not revalidate identity immediately before clobbering assets.'
    Assert ($publishScriptText.Contains('Assert-ContextMiniReleaseAssetDigests')) 'Draft assets are not compared with the tested bytes before publication.'

    $actionlintText = [IO.File]::ReadAllText($actionlintValidator)
    Assert ($actionlintText.Contains("`$actionlintVersion = '1.7.12'")) 'actionlint version is not fixed.'
    Assert ($actionlintText.Contains('https://github.com/rhysd/actionlint/releases/download/')) 'actionlint is not downloaded from its official release source.'
    Assert ($actionlintText.Contains("`$expectedSha256 = '6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9'")) 'actionlint archive hash is not pinned.'
    Assert ($actionlintText.Contains("Get-ChildItem -LiteralPath (Join-Path `$root '.github\workflows')")) 'actionlint does not enumerate every workflow.'
}

Run 'release documentation covers package choice, runtime notices, maintenance, hashes, and signing reality' {
    $text = [IO.File]::ReadAllText($readme)
    Assert ($text.Contains('ContextMini-vX.Y.Z-win-x64-self-contained.zip')) 'README does not identify the self-contained download.'
    Assert ($text.Contains('ContextMini-vX.Y.Z-win-x64.zip')) 'README does not identify the framework-dependent download.'
    Assert ($text.Contains('THIRD-PARTY-NOTICES.txt')) 'README does not identify self-contained third-party notices.'
    Assert ($text.Contains('RUNTIME-PACKS.json')) 'README does not explain runtime-pack provenance metadata.'
    Assert ($text.Contains('maintenance-automation.tests.ps1')) 'README does not document maintenance automation tests.'
    Assert ($text.Contains('CodeQL')) 'README does not document CodeQL analysis.'
    Assert ($text.Contains('Dependabot')) 'README does not document dependency/toolchain maintenance.'
    Assert ($text.Contains('Get-FileHash')) 'README has no PowerShell checksum verification.'
    Assert ($text.Contains('SmartScreen')) 'README does not explain the unsigned SmartScreen experience.'
    Assert ($text.Contains('attestation verification runs only when GitHub reports that the Release is immutable')) 'README overstates release attestation availability.'
    Assert ($text.Contains('no attestation guarantee')) 'README does not state the mutable-release attestation limitation.'
}

Write-Output "RESULT passed=$passed failed=0"
