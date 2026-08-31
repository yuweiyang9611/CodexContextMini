Set-StrictMode -Version Latest

$script:ReleaseSemverPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?$'
$script:RuntimeRestoreSource = 'https://api.nuget.org/v3/index.json'

function Get-ContextMiniReleaseLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Version)

    if ($Version -cnotmatch $script:ReleaseSemverPattern) { throw "Invalid release SemVer: $Version" }
    $frameworkArchive = "ContextMini-v$Version-win-x64.zip"
    $selfContainedArchive = "ContextMini-v$Version-win-x64-self-contained.zip"
    return [PSCustomObject]@{
        Version = $Version
        FrameworkArchive = $frameworkArchive
        SelfContainedArchive = $selfContainedArchive
        Checksums = 'SHA256SUMS.txt'
        ZipNames = [string[]]@($frameworkArchive, $selfContainedArchive)
        AssetNames = [string[]]@($frameworkArchive, $selfContainedArchive, 'SHA256SUMS.txt')
    }
}

function Get-ContextMiniSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $bytes = $sha.ComputeHash($stream) }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
    return ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()
}

function New-ContextMiniDeterministicZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$SourceDirectory,
        [Parameter(Mandatory=$true)][string]$ArchivePath
    )

    Add-Type -AssemblyName System.IO.Compression
    $source = [IO.Path]::GetFullPath($SourceDirectory)
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Archive source directory is missing: $source" }
    $sourcePrefix = $source.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $relativeNames = @(
        Get-ChildItem -LiteralPath $source -File -Recurse |
            ForEach-Object {
                if (-not $_.FullName.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Archive input escaped the publish directory: $($_.FullName)"
                }
                $_.FullName.Substring($sourcePrefix.Length).Replace('\','/')
            }
    )
    [Array]::Sort($relativeNames, [StringComparer]::Ordinal)
    $fixedTimestamp = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $archiveStream = [IO.File]::Open($ArchivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($relativeName in $relativeNames) {
                $entry = $archive.CreateEntry($relativeName, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $fixedTimestamp
                $sourcePath = Join-Path $source ($relativeName.Replace('/', [IO.Path]::DirectorySeparatorChar))
                $input = [IO.File]::Open($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try {
                    $outputStream = $entry.Open()
                    try { $input.CopyTo($outputStream) }
                    finally { $outputStream.Dispose() }
                }
                finally { $input.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $archiveStream.Dispose() }
}

function Get-ContextMiniRuntimePackMapFromDepsJson {
    param([Parameter(Mandatory=$true)][string]$Json)

    $deps = $Json | ConvertFrom-Json
    $librariesProperty = $deps.PSObject.Properties['libraries']
    if ($null -eq $librariesProperty) { throw 'ContextMini.deps.json has no libraries object.' }
    $packMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($libraryName in @($librariesProperty.Value.PSObject.Properties.Name)) {
        $match = [regex]::Match([string]$libraryName, '^runtimepack\.(?<id>[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?)/(?<version>[0-9A-Za-z](?:[0-9A-Za-z_.+-]*[0-9A-Za-z])?)$')
        if (-not $match.Success) { continue }
        $id = $match.Groups['id'].Value
        $version = $match.Groups['version'].Value
        $key = "$id/$version"
        if ($packMap.ContainsKey($key)) { throw "Duplicate runtime pack in ContextMini.deps.json: $key" }
        $packMap[$key] = [PSCustomObject]@{ Id = $id; Version = $version }
    }
    return $packMap
}

function Add-ContextMiniRuntimePackNotices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$PublishDirectory,
        [Parameter(Mandatory=$true)][string]$PackageRoot,
        [string]$RestoreSource = $script:RuntimeRestoreSource
    )

    $publish = [IO.Path]::GetFullPath($PublishDirectory)
    $packages = [IO.Path]::GetFullPath($PackageRoot)
    $packageRootPrefix = $packages.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $depsPath = Join-Path $publish 'ContextMini.deps.json'
    if (-not (Test-Path -LiteralPath $depsPath -PathType Leaf)) { throw "Self-contained dependency manifest is missing: $depsPath" }
    if (-not (Test-Path -LiteralPath $packages -PathType Container)) { throw "NuGet package root is missing: $packages" }

    $packMap = Get-ContextMiniRuntimePackMapFromDepsJson -Json ([IO.File]::ReadAllText($depsPath))
    if ($packMap.Count -eq 0) { throw 'ContextMini.deps.json identifies no runtimepack.* dependencies.' }

    $keys = [string[]]@($packMap.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $noticeRoot = Join-Path $publish 'runtime-notices'
    $manifestPath = Join-Path $publish 'RUNTIME-PACKS.json'
    $combinedNoticePath = Join-Path $publish 'THIRD-PARTY-NOTICES.txt'
    if ((Test-Path -LiteralPath $noticeRoot) -or (Test-Path -LiteralPath $manifestPath) -or (Test-Path -LiteralPath $combinedNoticePath)) {
        throw 'Runtime notice output already exists in the self-contained publish directory.'
    }

    [object[]]$packageRecords = @()
    $noticeBundles = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $totalNoticeFiles = 0
    foreach ($key in $keys) {
        $pack = $packMap[$key]
        $packageDirectory = [IO.Path]::GetFullPath((Join-Path (Join-Path $packages $pack.Id.ToLowerInvariant()) $pack.Version.ToLowerInvariant()))
        if (-not $packageDirectory.StartsWith($packageRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Runtime package path escaped the NuGet package root: $($pack.Id)/$($pack.Version)"
        }
        if (-not (Test-Path -LiteralPath $packageDirectory -PathType Container)) {
            throw "Restored runtime package directory is missing: $($pack.Id)/$($pack.Version)"
        }

        $candidateMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($file in @(Get-ChildItem -LiteralPath $packageDirectory -File)) {
            if (($file.Name -imatch '^LICENSE(?:\..+)?$') -or ($file.Name -imatch '^THIRD-PARTY-NOTICES(?:\..+)?$')) {
                if ($candidateMap.ContainsKey($file.Name)) { throw "Duplicate runtime notice file name: $($file.Name)" }
                $candidateMap[$file.Name] = $file
            }
        }
        $fileNames = [string[]]@($candidateMap.Keys)
        [Array]::Sort($fileNames, [StringComparer]::Ordinal)
        [object[]]$licenseRecords = @()
        [object[]]$noticeRecords = @()
        foreach ($fileName in $fileNames) {
            $sourceFile = $candidateMap[$fileName]
            $relativePath = "runtime-notices/$($pack.Id)/$($pack.Version)/$fileName"
            $destination = Join-Path $publish ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $destinationParent = Split-Path -Parent $destination
            $null = New-Item -ItemType Directory -Path $destinationParent -Force
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $destination
            $record = [PSCustomObject][ordered]@{
                path = $relativePath
                sha256 = Get-ContextMiniSha256 -Path $destination
            }
            if ($fileName -imatch '^LICENSE(?:\..+)?$') { $licenseRecords += $record }
            else {
                $noticeRecords += $record
                $totalNoticeFiles++
                $noticeHash = [string]$record.sha256
                if (-not $noticeBundles.ContainsKey($noticeHash)) {
                    $noticeText = [IO.File]::ReadAllText($sourceFile.FullName)
                    $normalizedNoticeText = ($noticeText -replace "`r`n", "`n" -replace "`r", "`n")
                    $normalizedNoticeText = ($normalizedNoticeText -replace "`n+\z", '') + "`n"
                    $noticeBundles[$noticeHash] = [PSCustomObject]@{
                        Text = $normalizedNoticeText
                        Origins = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
                    }
                }
                if ($noticeBundles[$noticeHash].Origins.ContainsKey($relativePath)) { throw "Duplicate runtime notice origin: $relativePath" }
                $noticeBundles[$noticeHash].Origins[$relativePath] = [PSCustomObject]@{
                    Id = [string]$pack.Id
                    Version = [string]$pack.Version
                    Path = $relativePath
                }
            }
        }
        if ($licenseRecords.Count -eq 0) { throw "Runtime pack supplies no root LICENSE file: $($pack.Id)/$($pack.Version)" }
        $packageRecords += [PSCustomObject][ordered]@{
            id = [string]$pack.Id
            version = [string]$pack.Version
            packageUrl = "https://www.nuget.org/packages/$($pack.Id)/$($pack.Version)"
            licenses = [object[]]$licenseRecords
            thirdPartyNotices = [object[]]$noticeRecords
        }
    }
    if ($totalNoticeFiles -eq 0) { throw 'The actual runtime packs supply no root THIRD-PARTY-NOTICES file.' }

    $noticeHashes = [string[]]@($noticeBundles.Keys)
    [Array]::Sort($noticeHashes, [StringComparer]::Ordinal)
    $combined = New-Object Text.StringBuilder
    $null = $combined.Append("Context Mini self-contained runtime third-party notices`n")
    $null = $combined.Append("`n")
    $null = $combined.Append("This file is generated from the runtimepack.* entries actually present in ContextMini.deps.json.`n")
    $null = $combined.Append("Restore source: $RestoreSource`n")
    $null = $combined.Append("Notice bodies are included once per source-file SHA-256; package references remain explicit.`n")
    $null = $combined.Append("`nRuntime packs:`n")
    foreach ($package in $packageRecords) {
        $null = $combined.Append("`nPackage: $($package.id)/$($package.version)`n")
        $null = $combined.Append("Source: $RestoreSource`n")
        $null = $combined.Append("Package URL: $($package.packageUrl)`n")
        foreach ($license in @($package.licenses)) {
            $null = $combined.Append("License file: $($license.path) (SHA-256: $($license.sha256))`n")
        }
        foreach ($notice in @($package.thirdPartyNotices)) {
            $null = $combined.Append("Notice file: $($notice.path) (SHA-256: $($notice.sha256))`n")
        }
    }
    $null = $combined.Append("`nThird-party notice texts:`n")
    foreach ($noticeHash in $noticeHashes) {
        $bundle = $noticeBundles[$noticeHash]
        $originPaths = [string[]]@($bundle.Origins.Keys)
        [Array]::Sort($originPaths, [StringComparer]::Ordinal)
        $null = $combined.Append("`n==============================================================================`n")
        $null = $combined.Append("Notice-SHA256: $noticeHash`n")
        $null = $combined.Append("Supplied by:`n")
        foreach ($originPath in $originPaths) {
            $origin = $bundle.Origins[$originPath]
            $null = $combined.Append("- $($origin.Id)/$($origin.Version): $($origin.Path)`n")
        }
        $null = $combined.Append("----- BEGIN NOTICE -----`n")
        $null = $combined.Append([string]$bundle.Text)
        $null = $combined.Append("----- END NOTICE -----`n")
    }
    [IO.File]::WriteAllText($combinedNoticePath, $combined.ToString(), (New-Object Text.UTF8Encoding($false)))

    $manifest = [PSCustomObject][ordered]@{
        formatVersion = 1
        restoreSource = $RestoreSource
        generatedFrom = 'ContextMini.deps.json runtimepack.* entries'
        combinedThirdPartyNotices = [PSCustomObject][ordered]@{
            path = 'THIRD-PARTY-NOTICES.txt'
            sha256 = Get-ContextMiniSha256 -Path $combinedNoticePath
            sourceNoticeSha256 = [string[]]$noticeHashes
        }
        packages = [object[]]$packageRecords
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($manifestPath, $manifestJson + "`n", (New-Object Text.UTF8Encoding($false)))
    return $manifest
}

function Get-ZipEntrySha256 {
    param([Parameter(Mandatory=$true)]$Entry)
    $stream = $Entry.Open()
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $bytes = $sha.ComputeHash($stream) }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
    return ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()
}

function Read-ZipEntryText {
    param([Parameter(Mandatory=$true)]$Entry)
    $stream = $Entry.Open()
    try {
        $reader = [IO.StreamReader]::new($stream, (New-Object Text.UTF8Encoding($false, $true)), $true)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Assert-ContextMiniArchiveManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ArchivePath,
        [Parameter(Mandatory=$true)][ValidateSet('FrameworkDependent','SelfContained')][string]$Kind
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $windowsEntries = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $entryName = [string]$entry.FullName
            $segments = @($entryName -split '/')
            if ([string]::IsNullOrWhiteSpace($entryName) -or $entryName.Contains('\') -or $entryName.StartsWith('/', [StringComparison]::Ordinal) -or
                $entryName -match '^[A-Za-z]:' -or $entryName.EndsWith('/', [StringComparison]::Ordinal) -or
                @($segments | Where-Object { ($_ -ceq '') -or ($_ -ceq '.') -or ($_ -ceq '..') }).Count -gt 0) {
                throw "Release ZIP has an unsafe entry name: $entryName"
            }
            foreach ($segment in $segments) {
                $deviceBase = ($segment -split '\.', 2)[0]
                if ($segment -match '[<>:"|?*\x00-\x1f]' -or $segment.EndsWith('.', [StringComparison]::Ordinal) -or
                    $segment.EndsWith(' ', [StringComparison]::Ordinal) -or $deviceBase -imatch '^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
                    throw "Release ZIP has a Windows-unsafe entry name: $entryName"
                }
            }
            if ($entries.ContainsKey($entry.FullName)) { throw "Release ZIP has a duplicate entry: $($entry.FullName)" }
            if (-not $windowsEntries.Add($entryName)) { throw "Release ZIP has a Windows-ambiguous entry name: $entryName" }
            $entries[$entry.FullName] = $entry
        }
        foreach ($required in @('ContextMini.exe','ContextMini.dll','ContextMini.deps.json','ContextMini.runtimeconfig.json','LICENSE')) {
            if (-not $entries.ContainsKey($required)) { throw "Release ZIP is missing $required ($Kind)." }
        }
        $runtimeFiles = @('coreclr.dll','hostfxr.dll','hostpolicy.dll')
        $runtimeNoticeEntries = @($entries.Keys | Where-Object { $_.StartsWith('runtime-notices/', [StringComparison]::Ordinal) })
        $embeddedPackMap = Get-ContextMiniRuntimePackMapFromDepsJson -Json (Read-ZipEntryText -Entry $entries['ContextMini.deps.json'])
        if ($Kind -ceq 'FrameworkDependent') {
            foreach ($forbidden in $runtimeFiles) {
                if ($entries.ContainsKey($forbidden)) { throw "Framework-dependent release ZIP unexpectedly contains $forbidden." }
            }
            if ($entries.ContainsKey('RUNTIME-PACKS.json') -or $entries.ContainsKey('THIRD-PARTY-NOTICES.txt') -or $runtimeNoticeEntries.Count -gt 0) {
                throw 'Framework-dependent release ZIP unexpectedly contains self-contained runtime notices.'
            }
            if ($embeddedPackMap.Count -gt 0) { throw 'Framework-dependent ContextMini.deps.json unexpectedly identifies runtimepack.* dependencies.' }
            return
        }

        foreach ($required in $runtimeFiles) {
            if (-not $entries.ContainsKey($required)) { throw "Self-contained release ZIP is missing $required." }
        }
        if (-not $entries.ContainsKey('RUNTIME-PACKS.json')) { throw 'Self-contained release ZIP is missing RUNTIME-PACKS.json.' }
        if (-not $entries.ContainsKey('THIRD-PARTY-NOTICES.txt')) { throw 'Self-contained release ZIP is missing THIRD-PARTY-NOTICES.txt.' }
        if ($runtimeNoticeEntries.Count -eq 0) { throw 'Self-contained release ZIP has no runtime-notices entries.' }

        $manifest = (Read-ZipEntryText -Entry $entries['RUNTIME-PACKS.json']) | ConvertFrom-Json
        if ([int]$manifest.formatVersion -ne 1) { throw 'Unsupported RUNTIME-PACKS.json formatVersion.' }
        if ([string]$manifest.restoreSource -cne $script:RuntimeRestoreSource) { throw 'RUNTIME-PACKS.json has an unexpected restore source.' }
        $combinedProperty = $manifest.PSObject.Properties['combinedThirdPartyNotices']
        if ($null -eq $combinedProperty) { throw 'RUNTIME-PACKS.json does not index THIRD-PARTY-NOTICES.txt.' }
        $combinedRecord = $combinedProperty.Value
        if ([string]$combinedRecord.path -cne 'THIRD-PARTY-NOTICES.txt') { throw 'RUNTIME-PACKS.json has an unexpected combined notice path.' }
        $combinedHash = [string]$combinedRecord.sha256
        if ($combinedHash -cnotmatch '^[0-9a-f]{64}$') { throw 'RUNTIME-PACKS.json has an invalid combined notice SHA-256.' }
        if ((Get-ZipEntrySha256 -Entry $entries['THIRD-PARTY-NOTICES.txt']) -cne $combinedHash) { throw 'THIRD-PARTY-NOTICES.txt SHA-256 mismatch.' }
        $combinedText = Read-ZipEntryText -Entry $entries['THIRD-PARTY-NOTICES.txt']
        if (-not $combinedText.Contains("Restore source: $($manifest.restoreSource)")) { throw 'THIRD-PARTY-NOTICES.txt does not identify the restore source.' }
        $packages = @($manifest.packages)
        if ($packages.Count -eq 0) { throw 'RUNTIME-PACKS.json lists no runtime packages.' }
        $expectedPackMap = $embeddedPackMap
        if ($expectedPackMap.Count -eq 0) { throw 'Self-contained ContextMini.deps.json identifies no runtimepack.* dependencies.' }
        $referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $packageKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $noticeCount = 0
        $noticeHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($package in $packages) {
            $id = [string]$package.id
            $version = [string]$package.version
            if ($id -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$' -or $version -cnotmatch '^[0-9A-Za-z](?:[0-9A-Za-z_.+-]*[0-9A-Za-z])?$') { throw 'RUNTIME-PACKS.json contains an invalid package identity.' }
            $packageKey = "$id/$version"
            if (-not $packageKeys.Add($packageKey)) { throw "RUNTIME-PACKS.json repeats runtime package $packageKey." }
            if (-not $expectedPackMap.ContainsKey($packageKey)) { throw "RUNTIME-PACKS.json lists a runtime package not present in ContextMini.deps.json: $packageKey" }
            if ([string]$package.packageUrl -cne "https://www.nuget.org/packages/$id/$version") { throw "RUNTIME-PACKS.json has an unexpected package URL for $packageKey." }
            if (-not $combinedText.Contains("Package: $packageKey")) { throw "THIRD-PARTY-NOTICES.txt does not identify runtime package $packageKey." }
            if (-not $combinedText.Contains("Package URL: $($package.packageUrl)")) { throw "THIRD-PARTY-NOTICES.txt does not identify the package source for $packageKey." }
            $licenses = @($package.licenses)
            $notices = @($package.thirdPartyNotices)
            if ($licenses.Count -eq 0) { throw "RUNTIME-PACKS.json lists no license for $packageKey." }
            $noticeCount += $notices.Count
            foreach ($record in @($licenses + $notices)) {
                $path = [string]$record.path
                $expectedPrefix = "runtime-notices/$id/$version/"
                if (-not $path.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) { throw "Runtime notice path does not match package ${packageKey}: $path" }
                if (-not $entries.ContainsKey($path)) { throw "Runtime notice entry is missing: $path" }
                if (-not $referenced.Add($path)) { throw "Runtime notice entry is referenced more than once: $path" }
                $expectedHash = [string]$record.sha256
                if ($expectedHash -cnotmatch '^[0-9a-f]{64}$') { throw "Runtime notice SHA-256 is invalid: $path" }
                $actualHash = Get-ZipEntrySha256 -Entry $entries[$path]
                if ($actualHash -cne $expectedHash) { throw "Runtime notice SHA-256 mismatch: $path" }
                if (-not $combinedText.Contains("$path (SHA-256: $expectedHash)")) { throw "THIRD-PARTY-NOTICES.txt does not index runtime notice file: $path" }
            }
            foreach ($notice in $notices) {
                $noticeHash = [string]$notice.sha256
                $null = $noticeHashes.Add($noticeHash)
                if (-not $combinedText.Contains("Notice-SHA256: $noticeHash")) { throw "THIRD-PARTY-NOTICES.txt does not identify notice content $noticeHash." }
                $rawText = Read-ZipEntryText -Entry $entries[[string]$notice.path]
                $normalizedRawText = ($rawText -replace "`r`n", "`n" -replace "`r", "`n")
                $normalizedRawText = ($normalizedRawText -replace "`n+\z", '') + "`n"
                if (-not $combinedText.Contains($normalizedRawText)) { throw "THIRD-PARTY-NOTICES.txt omits the complete notice text from $($notice.path)." }
            }
        }
        foreach ($expectedPackKey in $expectedPackMap.Keys) {
            if (-not $packageKeys.Contains($expectedPackKey)) { throw "RUNTIME-PACKS.json omits runtime package from ContextMini.deps.json: $expectedPackKey" }
        }
        if ($noticeCount -eq 0) { throw 'RUNTIME-PACKS.json lists no THIRD-PARTY-NOTICES file.' }
        $indexedNoticeHashes = [string[]]@($combinedRecord.sourceNoticeSha256)
        [Array]::Sort($indexedNoticeHashes, [StringComparer]::Ordinal)
        $actualNoticeHashes = [string[]]@($noticeHashes)
        [Array]::Sort($actualNoticeHashes, [StringComparer]::Ordinal)
        if (($indexedNoticeHashes.Count -ne $actualNoticeHashes.Count) -or (Compare-Object $actualNoticeHashes $indexedNoticeHashes -CaseSensitive)) {
            throw 'RUNTIME-PACKS.json combined notice content hashes do not match the actual notice files.'
        }
        foreach ($entryName in $runtimeNoticeEntries) {
            if (-not $referenced.Contains($entryName)) { throw "Unindexed runtime notice entry: $entryName" }
        }
    }
    finally { $archive.Dispose() }
}

function Read-ContextMiniChecksumManifest {
    param(
        [Parameter(Mandatory=$true)][string]$ChecksumPath,
        [Parameter(Mandatory=$true)][string[]]$ArchiveNames
    )
    $lines = @([IO.File]::ReadAllLines($ChecksumPath))
    if ($lines.Count -ne $ArchiveNames.Count) { throw "Expected $($ArchiveNames.Count) checksum lines, found $($lines.Count)." }
    $manifest = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($line in $lines) {
        if ($line -cnotmatch '^(?<hash>[0-9a-f]{64})  (?<name>[^\\/]+\.zip)$') { throw "Invalid checksum line: $line" }
        if ($manifest.ContainsKey($Matches.name)) { throw "Duplicate checksum entry: $($Matches.name)" }
        $manifest[$Matches.name] = $Matches.hash
    }
    foreach ($archiveName in $ArchiveNames) {
        if (-not $manifest.ContainsKey($archiveName)) { throw "Missing checksum entry: $archiveName" }
    }
    return $manifest
}

function Assert-ContextMiniReleaseAssetDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$AssetDirectory,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $directory = [IO.Path]::GetFullPath($AssetDirectory)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Release asset directory is missing: $directory" }
    $layout = Get-ContextMiniReleaseLayout -Version $Version
    $expectedNames = [string[]]@($layout.AssetNames)
    [Array]::Sort($expectedNames, [StringComparer]::Ordinal)
    $actualNames = [string[]]@(Get-ChildItem -LiteralPath $directory -File | ForEach-Object Name)
    [Array]::Sort($actualNames, [StringComparer]::Ordinal)
    if (($actualNames.Count -ne $expectedNames.Count) -or (Compare-Object $expectedNames $actualNames -CaseSensitive)) {
        throw "Unexpected release assets: $($actualNames -join ', ')"
    }
    $checksumPath = Join-Path $directory $layout.Checksums
    $checksums = Read-ContextMiniChecksumManifest -ChecksumPath $checksumPath -ArchiveNames $layout.ZipNames
    foreach ($zipName in $layout.ZipNames) {
        $zipPath = Join-Path $directory $zipName
        $actualHash = Get-ContextMiniSha256 -Path $zipPath
        if ($actualHash -cne $checksums[$zipName]) { throw "SHA-256 mismatch: $zipName" }
    }
    Assert-ContextMiniArchiveManifest -ArchivePath (Join-Path $directory $layout.FrameworkArchive) -Kind FrameworkDependent
    Assert-ContextMiniArchiveManifest -ArchivePath (Join-Path $directory $layout.SelfContainedArchive) -Kind SelfContained
    return $layout
}

function Resolve-ContextMiniReleaseState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$Tag,
        [Parameter(Mandatory=$true)][string]$SourceSha,
        [AllowNull()][string]$TagCommit,
        [AllowNull()][object]$Release,
        [bool]$TagIsAncestor = $false,
        [switch]$RequireCompleteDraft
    )

    $layout = Get-ContextMiniReleaseLayout -Version $Version
    if ($Tag -cne "v$Version") { throw 'Release tag does not match VERSION.' }
    if ($SourceSha -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { throw 'Source SHA is invalid.' }
    $normalizedTagCommit = if ([string]::IsNullOrWhiteSpace($TagCommit)) { $null } else { [string]$TagCommit }
    if (($null -ne $normalizedTagCommit) -and ($normalizedTagCommit -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$')) { throw 'Tag commit SHA is invalid.' }

    if ($null -eq $Release) {
        if (($null -ne $normalizedTagCommit) -and ($normalizedTagCommit -cne $SourceSha)) { throw 'The release tag already points to another commit.' }
        return [PSCustomObject]@{ Publish = $true; Recover = $false; CompareTested = $true; State = 'fresh' }
    }

    $actual = @($Release.assets | ForEach-Object { [string]$_.name })
    $uniqueAssetNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($assetName in $actual) {
        if (-not $uniqueAssetNames.Add($assetName)) { throw "Release repeats asset metadata: $assetName" }
    }
    $missing = @($layout.AssetNames | Where-Object { $actual -cnotcontains $_ })
    $unexpected = @($actual | Where-Object { $layout.AssetNames -cnotcontains $_ })
    if ($unexpected.Count -gt 0) { throw "Release has unexpected assets: $($unexpected -join ', ')" }
    $expectedPrerelease = $Version.Contains('-')

    if ([bool]$Release.isDraft) {
        if ([string]$Release.tagName -cne $Tag) { throw 'Draft release tag does not match the requested tag.' }
        if ([string]$Release.name -cne "Context Mini $Version") { throw 'Draft release title does not match the automated title.' }
        if ([string]$Release.targetCommitish -cne $SourceSha) { throw 'Draft release targets a different commit; refusing automatic recovery.' }
        if (($null -ne $normalizedTagCommit) -and ($normalizedTagCommit -cne $SourceSha)) { throw 'Draft release tag points to a different commit; refusing automatic recovery.' }
        if ([bool]$Release.isPrerelease -ne $expectedPrerelease) { throw 'Draft release prerelease state does not match VERSION.' }
        if ($RequireCompleteDraft -and $missing.Count -gt 0) { throw "Draft release is missing: $($missing -join ', ')" }
        return [PSCustomObject]@{ Publish = $false; Recover = $true; CompareTested = $true; State = 'draft' }
    }

    if ($null -eq $normalizedTagCommit) { throw 'Existing published release has no matching tag.' }
    if (-not $TagIsAncestor) { throw 'Existing published release tag is not an ancestor of the tested commit.' }
    if ($missing.Count -gt 0) { throw "Published release is missing: $($missing -join ', ')" }
    if ([bool]$Release.isPrerelease -ne $expectedPrerelease) { throw 'Published release prerelease state does not match VERSION.' }
    return [PSCustomObject]@{ Publish = $false; Recover = $false; CompareTested = $false; State = 'published' }
}

function Assert-ContextMiniReleaseAssetDigests {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$Release,
        [Parameter(Mandatory=$true)][string]$AssetDirectory,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $layout = Assert-ContextMiniReleaseAssetDirectory -AssetDirectory $AssetDirectory -Version $Version
    $remoteAssets = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($asset in @($Release.assets)) {
        $assetName = [string]$asset.name
        if ($remoteAssets.ContainsKey($assetName)) { throw "Duplicate Release asset metadata: $assetName" }
        $remoteAssets[$assetName] = $asset
    }
    $remoteNames = [string[]]@($remoteAssets.Keys)
    [Array]::Sort($remoteNames, [StringComparer]::Ordinal)
    $expectedNames = [string[]]@($layout.AssetNames)
    [Array]::Sort($expectedNames, [StringComparer]::Ordinal)
    if (($remoteNames.Count -ne $expectedNames.Count) -or (Compare-Object $expectedNames $remoteNames -CaseSensitive)) {
        throw "Unexpected Release assets: $($remoteNames -join ', ')"
    }
    foreach ($assetName in $layout.AssetNames) {
        $localHash = Get-ContextMiniSha256 -Path (Join-Path $AssetDirectory $assetName)
        $digestProperty = $remoteAssets[$assetName].PSObject.Properties['digest']
        $remoteDigest = if ($null -eq $digestProperty) { '' } else { [string]$digestProperty.Value }
        if ($remoteDigest -cnotmatch '^sha256:(?<hash>[0-9a-f]{64})$') { throw "Release asset has no valid SHA-256 digest: $assetName" }
        if ($localHash -cne $Matches.hash.ToLowerInvariant()) { throw "Release asset digest mismatch: $assetName" }
    }
    return [PSCustomObject]@{ Layout = $layout; RemoteAssets = $remoteAssets }
}

function Assert-ContextMiniPublishedReleaseAssets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$Release,
        [Parameter(Mandatory=$true)][string]$DownloadedDirectory,
        [Parameter(Mandatory=$true)][string]$Version,
        [string]$TrustedDirectory,
        [switch]$CompareTested
    )

    if ([bool]$Release.isDraft) { throw 'The GitHub Release is still a draft.' }
    $metadata = Assert-ContextMiniReleaseAssetDigests -Release $Release -AssetDirectory $DownloadedDirectory -Version $Version
    $layout = $metadata.Layout
    if ($CompareTested) {
        if ([string]::IsNullOrWhiteSpace($TrustedDirectory)) { throw 'TrustedDirectory is required when CompareTested is enabled.' }
        $null = Assert-ContextMiniReleaseAssetDirectory -AssetDirectory $TrustedDirectory -Version $Version
    }

    $verificationPaths = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($assetName in $layout.AssetNames) {
        $downloadedPath = Join-Path $DownloadedDirectory $assetName
        $downloadedHash = Get-ContextMiniSha256 -Path $downloadedPath
        $verificationPath = $downloadedPath
        if ($CompareTested) {
            $trustedPath = Join-Path $TrustedDirectory $assetName
            $trustedHash = Get-ContextMiniSha256 -Path $trustedPath
            if ($downloadedHash -cne $trustedHash) { throw "Published asset differs from the tested artifact: $assetName" }
            $verificationPath = $trustedPath
        }
        $verificationPaths[$assetName] = $verificationPath
    }
    return [PSCustomObject]@{
        IsImmutable = [bool]$Release.isImmutable
        VerificationPaths = $verificationPaths
        Layout = $layout
    }
}

function Select-ContextMiniHighestStableReleaseTag {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object[]]$Releases)

    $highest = $null
    foreach ($release in $Releases) {
        if ([bool]$release.isDraft -or [bool]$release.isPrerelease) { continue }
        $match = [regex]::Match([string]$release.tagName, '^v(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)$')
        if (-not $match.Success) { continue }
        $parts = @(
            [bigint]::Parse($match.Groups['major'].Value),
            [bigint]::Parse($match.Groups['minor'].Value),
            [bigint]::Parse($match.Groups['patch'].Value)
        )
        $isHigher = $null -eq $highest
        if (-not $isHigher) {
            for ($index = 0; $index -lt 3; $index++) {
                if ($parts[$index] -gt $highest.Parts[$index]) { $isHigher = $true; break }
                if ($parts[$index] -lt $highest.Parts[$index]) { break }
            }
        }
        if ($isHigher) { $highest = [PSCustomObject]@{ Tag = [string]$release.tagName; Parts = $parts } }
    }
    if ($null -eq $highest) { return $null }
    return [string]$highest.Tag
}

function Write-ContextMiniGitHubOutput {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Value
    )
    if ($Name -cnotmatch '^[a-z_][a-z0-9_]*$') { throw "Invalid GitHub output name: $Name" }
    if ($Value.Contains("`r") -or $Value.Contains("`n")) { throw "GitHub output value contains a newline: $Name" }
    [IO.File]::AppendAllText($Path, "$Name=$Value`n", (New-Object Text.UTF8Encoding($false)))
}

Export-ModuleMember -Function @(
    'Get-ContextMiniReleaseLayout',
    'Get-ContextMiniSha256',
    'New-ContextMiniDeterministicZip',
    'Add-ContextMiniRuntimePackNotices',
    'Assert-ContextMiniArchiveManifest',
    'Assert-ContextMiniReleaseAssetDirectory',
    'Resolve-ContextMiniReleaseState',
    'Assert-ContextMiniReleaseAssetDigests',
    'Assert-ContextMiniPublishedReleaseAssets',
    'Select-ContextMiniHighestStableReleaseTag',
    'Write-ContextMiniGitHubOutput'
)
