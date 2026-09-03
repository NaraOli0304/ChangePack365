function Test-CP365CasePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ })]
        [string]$PackagePath,

        [string]$ExpectedSignerThumbprint
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $resolvedPackage = (Resolve-Path -LiteralPath $PackagePath).Path
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $temporaryRoot = $null
    $root = $null
    $filesChecked = 0
    $ledgerEntries = 0
    $ledgerHead = $null
    $status = 'Invalid'
    $signatureStatus = 'NotSigned'
    $signerThumbprint = $null
    $signerSubject = $null
    $authenticityEstablished = $false

    $normalizedExpectedThumbprint = if (
        -not [string]::IsNullOrWhiteSpace($ExpectedSignerThumbprint)
    ) {
        $ExpectedSignerThumbprint.Replace(' ', '').ToUpperInvariant()
    }
    else {
        $null
    }
    if (
        $null -ne $normalizedExpectedThumbprint -and
        $normalizedExpectedThumbprint -notmatch '^[A-F0-9]{32,128}

    function Test-CP365SafeRelativePath {
        param([Parameter(Mandatory)][string]$Path)

        if (
            [string]::IsNullOrWhiteSpace($Path) -or
            [IO.Path]::IsPathRooted($Path) -or
            $Path -match '^[A-Za-z]:' -or
            $Path.StartsWith('/') -or
            $Path.StartsWith('\')
        ) {
            return $false
        }

        $segments = $Path.Replace('\', '/').Split('/')
        return -not ($segments | Where-Object { $_ -in @('', '.', '..') })
    }

    try {
        $sourceItem = Get-Item -LiteralPath $resolvedPackage
        if ($sourceItem.PSIsContainer) {
            $root = $sourceItem.FullName
        }
        elseif ($sourceItem.Extension -ieq '.zip') {
            $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "cp365-verify-$([guid]::NewGuid().Guid)"
            $null = New-Item -ItemType Directory -Path $temporaryRoot
            $root = $temporaryRoot

            $archive = [IO.Compression.ZipFile]::OpenRead($sourceItem.FullName)
            try {
                $entryNames = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase
                )
                $rootPrefix = [IO.Path]::GetFullPath($root).TrimEnd(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar
                ) + [IO.Path]::DirectorySeparatorChar

                foreach ($entry in $archive.Entries) {
                    $entryName = $entry.FullName.Replace('\', '/')
                    if ($entryName.EndsWith('/')) {
                        $entryName = $entryName.TrimEnd('/')
                        if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
                    }

                    if (-not (Test-CP365SafeRelativePath -Path $entryName)) {
                        throw "Unsafe ZIP entry path: $($entry.FullName)"
                    }
                    if (-not $entryNames.Add($entryName)) {
                        throw "Duplicate ZIP entry path: $entryName"
                    }

                    $target = [IO.Path]::GetFullPath((Join-Path $root $entryName))
                    if (-not $target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "ZIP entry escapes the extraction directory: $entryName"
                    }

                    $unixFileType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
                    $dosAttributes = ($entry.ExternalAttributes -band 0xFFFF)
                    if (
                        $unixFileType -eq 0xA000 -or
                        ($dosAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0
                    ) {
                        throw "ZIP links are not allowed: $entryName"
                    }
                }
            }
            finally {
                $archive.Dispose()
            }

            [IO.Compression.ZipFile]::ExtractToDirectory($sourceItem.FullName, $root)
        }
        else {
            throw 'PackagePath must identify a ZIP file or an extracted package directory.'
        }

        $links = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object {
            $_.LinkType -or
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
        if ($links.Count -gt 0) {
            throw "Package contains link or reparse-point entries: $($links[0].FullName)"
        }

        $manifestPath = Join-Path $root 'manifest.json'
        $bundlePath = Join-Path $root 'bundle.json'
        $contractPath = Join-Path $root 'contract.json'
        $ledgerPath = Join-Path $root 'ledger.jsonl'

        foreach ($requiredPath in @($manifestPath, $bundlePath, $contractPath, $ledgerPath)) {
            if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
                $errors.Add("Required package file is missing: $(Split-Path -Leaf $requiredPath)")
            }
        }
        if ($errors.Count -gt 0) {
            throw 'Required package files are missing.'
        }

        $bundle = Get-Content -LiteralPath $bundlePath -Raw | ConvertFrom-Json
        if ([int]$bundle.formatVersion -ne 1) {
            $errors.Add("Unsupported bundle format version: $($bundle.formatVersion)")
        }

        $manifest = @(
            Get-Content -LiteralPath $manifestPath -Raw |
                ConvertFrom-Json
        )
        if ($manifest.Count -eq 0) {
            $errors.Add('Package manifest is empty.')
        }

        $manifestPaths = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($entry in $manifest) {
            $relative = [string]$entry.path
            if (-not (Test-CP365SafeRelativePath -Path $relative)) {
                $errors.Add("Unsafe manifest path: $relative")
                continue
            }

            $relative = $relative.Replace('\', '/')
            if (-not $manifestPaths.Add($relative)) {
                $errors.Add("Duplicate manifest path: $relative")
                continue
            }

            $candidate = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $errors.Add("Manifest file is missing: $relative")
                continue
            }

            $item = Get-Item -LiteralPath $candidate
            if ([long]$entry.bytes -ne $item.Length) {
                $errors.Add("File size mismatch: $relative")
            }
            if ([string]$entry.sha256 -ne (Get-CP365Hash -Path $candidate)) {
                $errors.Add("SHA256 mismatch: $relative")
            }
            $filesChecked++
        }

        $declaredSignatureFile = $null
        if (
            $bundle.PSObject.Properties['signature'] -and
            $null -ne $bundle.signature
        ) {
            $declaredSignatureFile = [string]$bundle.signature.file
        }

        $actualPaths = @(
            Get-ChildItem -LiteralPath $root -File -Recurse -Force |
                ForEach-Object {
                    [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
                } |
                Where-Object {
                    $_ -ne 'manifest.json' -and
                    $_ -ne $declaredSignatureFile
                }
        )
        foreach ($actualPath in $actualPaths) {
            if (-not $manifestPaths.Contains($actualPath)) {
                $errors.Add("Unexpected package file: $actualPath")
            }
        }

        if (-not $manifestPaths.Contains('bundle.json')) {
            $errors.Add('bundle.json is not covered by the package manifest.')
        }

        if ($errors.Count -eq 0 -and $null -ne $declaredSignatureFile) {
            if (-not (Test-CP365SafeRelativePath -Path $declaredSignatureFile)) {
                $errors.Add("Unsafe signature path: $declaredSignatureFile")
            }
            elseif (
                [string]$bundle.signature.format -ne 'CMS/PKCS7' -or
                [string]$bundle.signature.digestAlgorithm -ne 'SHA256'
            ) {
                $errors.Add('Unsupported manifest signature metadata.')
            }
            elseif ($manifestPaths.Contains($declaredSignatureFile)) {
                $errors.Add('Detached signature must not be listed inside the signed manifest.')
            }
            else {
                $signaturePath = Join-Path $root $declaredSignatureFile
                if (-not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) {
                    $errors.Add("Declared signature file is missing: $declaredSignatureFile")
                }
                else {
                    try {
                        Add-Type -AssemblyName System.Security.Cryptography.Pkcs
                        $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
                        $contentInfo = [System.Security.Cryptography.Pkcs.ContentInfo]::new(
                            $manifestBytes
                        )
                        $signedCms = [System.Security.Cryptography.Pkcs.SignedCms]::new(
                            $contentInfo,
                            $true
                        )
                        $signedCms.Decode([IO.File]::ReadAllBytes($signaturePath))
                        if ($signedCms.SignerInfos.Count -ne 1) {
                            throw 'Manifest signature must contain exactly one signer.'
                        }
                        $signedCms.CheckSignature($true)
                        $signerCertificate = $signedCms.SignerInfos[0].Certificate
                        if ($null -eq $signerCertificate) {
                            throw 'Manifest signature does not embed the signer certificate.'
                        }

                        $signerThumbprint = $signerCertificate.Thumbprint.Replace(
                            ' ',
                            ''
                        ).ToUpperInvariant()
                        $signerSubject = $signerCertificate.Subject
                        $declaredThumbprint = (
                            [string]$bundle.signature.signerThumbprint
                        ).Replace(' ', '').ToUpperInvariant()
                        if ($signerThumbprint -ne $declaredThumbprint) {
                            throw 'Signer certificate does not match bundle metadata.'
                        }

                        $signatureStatus = 'Valid'
                        if ($null -ne $normalizedExpectedThumbprint) {
                            if ($signerThumbprint -ne $normalizedExpectedThumbprint) {
                                $signatureStatus = 'ExpectedSignerMismatch'
                                $errors.Add(
                                    'Signer certificate does not match the expected thumbprint.'
                                )
                            }
                            else {
                                $authenticityEstablished = $true
                            }
                        }
                        else {
                            $warnings.Add(
                                'Signature is valid, but signer identity was not anchored with an expected thumbprint.'
                            )
                        }
                    }
                    catch {
                        if ($signatureStatus -ne 'ExpectedSignerMismatch') {
                            $signatureStatus = 'Invalid'
                            $errors.Add("Manifest signature: $($_.Exception.Message)")
                        }
                    }
                }
            }
        }
        elseif (
            $errors.Count -eq 0 -and
            $null -ne $normalizedExpectedThumbprint
        ) {
            $signatureStatus = 'Missing'
            $errors.Add('ExpectedSignerThumbprint requires a signed manifest.')
        }

        if ($errors.Count -eq 0 -and [string]$bundle.kind -eq 'public') {
            $status = 'Unsupported'
            $warnings.Add(
                'Public bundles are redacted and their ledger is not yet independently verifiable.'
            )
        }
        elseif ($errors.Count -eq 0 -and [string]$bundle.kind -ne 'internal') {
            $errors.Add("Unsupported bundle kind: $($bundle.kind)")
        }

        if ($errors.Count -eq 0 -and $status -ne 'Unsupported') {
            $ledger = Test-CP365Ledger -CasePath $root
            $ledgerEntries = $ledger.Entries
            $ledgerHead = $ledger.HeadHash
            if (-not $ledger.Valid) {
                foreach ($ledgerError in $ledger.Errors) {
                    $errors.Add("Ledger: $ledgerError")
                }
            }
            elseif ([string]$bundle.ledgerHead -ne [string]$ledger.HeadHash) {
                $errors.Add('Bundle ledger head does not match the verified ledger.')
            }
        }

        $incomplete = $false
        if ($errors.Count -eq 0 -and $status -ne 'Unsupported') {
            $ledgerObjects = @(
                Get-Content -LiteralPath $ledgerPath |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ConvertFrom-Json -Depth 100
            )
            $incomplete = @(
                $ledgerObjects |
                    Where-Object {
                        $_.payload.PSObject.Properties['complete'] -and
                        $_.payload.complete -eq $false
                    }
            ).Count -gt 0

            foreach ($relative in $manifestPaths) {
                if (
                    $relative -notmatch '(?i)(collection-manifest|evidence-record).*\.json$'
                ) {
                    continue
                }

                $document = Get-Content -LiteralPath (Join-Path $root $relative) -Raw |
                    ConvertFrom-Json -Depth 100
                if (
                    $document.PSObject.Properties['complete'] -and
                    $document.complete -eq $false
                ) {
                    $incomplete = $true
                }
            }
        }

        if ($errors.Count -gt 0) {
            $status = 'Invalid'
        }
        elseif ($status -ne 'Unsupported') {
            $status = if ($incomplete) { 'Incomplete' } else { 'Valid' }
        }
    }
    catch {
        if ($errors.Count -eq 0 -or $errors[-1] -ne [string]$_.Exception.Message) {
            $errors.Add([string]$_.Exception.Message)
        }
        $status = 'Invalid'
    }
    finally {
        if ($null -ne $temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }

    [pscustomobject][ordered]@{
        PackagePath = $resolvedPackage
        Status = $status
        Valid = ($status -eq 'Valid')
        Complete = ($status -eq 'Valid')
        FilesChecked = $filesChecked
        LedgerEntries = $ledgerEntries
        LedgerHead = $ledgerHead
        SignatureStatus = $signatureStatus
        SignerThumbprint = $signerThumbprint
        SignerSubject = $signerSubject
        AuthenticityEstablished = $authenticityEstablished
        Errors = @($errors)
        Warnings = @($warnings)
    }
}

    ) {
        throw 'ExpectedSignerThumbprint must contain 32 to 128 hexadecimal characters.'
    }

    function Test-CP365SafeRelativePath {
        param([Parameter(Mandatory)][string]$Path)

        if (
            [string]::IsNullOrWhiteSpace($Path) -or
            [IO.Path]::IsPathRooted($Path) -or
            $Path -match '^[A-Za-z]:' -or
            $Path.StartsWith('/') -or
            $Path.StartsWith('\')
        ) {
            return $false
        }

        $segments = $Path.Replace('\', '/').Split('/')
        return -not ($segments | Where-Object { $_ -in @('', '.', '..') })
    }

    try {
        $sourceItem = Get-Item -LiteralPath $resolvedPackage
        if ($sourceItem.PSIsContainer) {
            $root = $sourceItem.FullName
        }
        elseif ($sourceItem.Extension -ieq '.zip') {
            $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "cp365-verify-$([guid]::NewGuid().Guid)"
            $null = New-Item -ItemType Directory -Path $temporaryRoot
            $root = $temporaryRoot

            $archive = [IO.Compression.ZipFile]::OpenRead($sourceItem.FullName)
            try {
                $entryNames = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase
                )
                $rootPrefix = [IO.Path]::GetFullPath($root).TrimEnd(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar
                ) + [IO.Path]::DirectorySeparatorChar

                foreach ($entry in $archive.Entries) {
                    $entryName = $entry.FullName.Replace('\', '/')
                    if ($entryName.EndsWith('/')) {
                        $entryName = $entryName.TrimEnd('/')
                        if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
                    }

                    if (-not (Test-CP365SafeRelativePath -Path $entryName)) {
                        throw "Unsafe ZIP entry path: $($entry.FullName)"
                    }
                    if (-not $entryNames.Add($entryName)) {
                        throw "Duplicate ZIP entry path: $entryName"
                    }

                    $target = [IO.Path]::GetFullPath((Join-Path $root $entryName))
                    if (-not $target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "ZIP entry escapes the extraction directory: $entryName"
                    }

                    $unixFileType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
                    $dosAttributes = ($entry.ExternalAttributes -band 0xFFFF)
                    if (
                        $unixFileType -eq 0xA000 -or
                        ($dosAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0
                    ) {
                        throw "ZIP links are not allowed: $entryName"
                    }
                }
            }
            finally {
                $archive.Dispose()
            }

            [IO.Compression.ZipFile]::ExtractToDirectory($sourceItem.FullName, $root)
        }
        else {
            throw 'PackagePath must identify a ZIP file or an extracted package directory.'
        }

        $links = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object {
            $_.LinkType -or
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
        if ($links.Count -gt 0) {
            throw "Package contains link or reparse-point entries: $($links[0].FullName)"
        }

        $manifestPath = Join-Path $root 'manifest.json'
        $bundlePath = Join-Path $root 'bundle.json'
        $contractPath = Join-Path $root 'contract.json'
        $ledgerPath = Join-Path $root 'ledger.jsonl'

        foreach ($requiredPath in @($manifestPath, $bundlePath, $contractPath, $ledgerPath)) {
            if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
                $errors.Add("Required package file is missing: $(Split-Path -Leaf $requiredPath)")
            }
        }
        if ($errors.Count -gt 0) {
            throw 'Required package files are missing.'
        }

        $bundle = Get-Content -LiteralPath $bundlePath -Raw | ConvertFrom-Json
        if ([int]$bundle.formatVersion -ne 1) {
            $errors.Add("Unsupported bundle format version: $($bundle.formatVersion)")
        }

        $manifest = @(
            Get-Content -LiteralPath $manifestPath -Raw |
                ConvertFrom-Json
        )
        if ($manifest.Count -eq 0) {
            $errors.Add('Package manifest is empty.')
        }

        $manifestPaths = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($entry in $manifest) {
            $relative = [string]$entry.path
            if (-not (Test-CP365SafeRelativePath -Path $relative)) {
                $errors.Add("Unsafe manifest path: $relative")
                continue
            }

            $relative = $relative.Replace('\', '/')
            if (-not $manifestPaths.Add($relative)) {
                $errors.Add("Duplicate manifest path: $relative")
                continue
            }

            $candidate = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $errors.Add("Manifest file is missing: $relative")
                continue
            }

            $item = Get-Item -LiteralPath $candidate
            if ([long]$entry.bytes -ne $item.Length) {
                $errors.Add("File size mismatch: $relative")
            }
            if ([string]$entry.sha256 -ne (Get-CP365Hash -Path $candidate)) {
                $errors.Add("SHA256 mismatch: $relative")
            }
            $filesChecked++
        }

        $actualPaths = @(
            Get-ChildItem -LiteralPath $root -File -Recurse -Force |
                ForEach-Object {
                    [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
                } |
                Where-Object { $_ -ne 'manifest.json' }
        )
        foreach ($actualPath in $actualPaths) {
            if (-not $manifestPaths.Contains($actualPath)) {
                $errors.Add("Unexpected package file: $actualPath")
            }
        }

        if (-not $manifestPaths.Contains('bundle.json')) {
            $errors.Add('bundle.json is not covered by the package manifest.')
        }

        if ($errors.Count -eq 0 -and [string]$bundle.kind -eq 'public') {
            $status = 'Unsupported'
            $warnings.Add(
                'Public bundles are redacted and their ledger is not yet independently verifiable.'
            )
        }
        elseif ($errors.Count -eq 0 -and [string]$bundle.kind -ne 'internal') {
            $errors.Add("Unsupported bundle kind: $($bundle.kind)")
        }

        if ($errors.Count -eq 0 -and $status -ne 'Unsupported') {
            $ledger = Test-CP365Ledger -CasePath $root
            $ledgerEntries = $ledger.Entries
            $ledgerHead = $ledger.HeadHash
            if (-not $ledger.Valid) {
                foreach ($ledgerError in $ledger.Errors) {
                    $errors.Add("Ledger: $ledgerError")
                }
            }
            elseif ([string]$bundle.ledgerHead -ne [string]$ledger.HeadHash) {
                $errors.Add('Bundle ledger head does not match the verified ledger.')
            }
        }

        $incomplete = $false
        if ($errors.Count -eq 0 -and $status -ne 'Unsupported') {
            $ledgerObjects = @(
                Get-Content -LiteralPath $ledgerPath |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ConvertFrom-Json -Depth 100
            )
            $incomplete = @(
                $ledgerObjects |
                    Where-Object {
                        $_.payload.PSObject.Properties['complete'] -and
                        $_.payload.complete -eq $false
                    }
            ).Count -gt 0

            foreach ($relative in $manifestPaths) {
                if (
                    $relative -notmatch '(?i)(collection-manifest|evidence-record).*\.json$'
                ) {
                    continue
                }

                $document = Get-Content -LiteralPath (Join-Path $root $relative) -Raw |
                    ConvertFrom-Json -Depth 100
                if (
                    $document.PSObject.Properties['complete'] -and
                    $document.complete -eq $false
                ) {
                    $incomplete = $true
                }
            }
        }

        if ($errors.Count -gt 0) {
            $status = 'Invalid'
        }
        elseif ($status -ne 'Unsupported') {
            $status = if ($incomplete) { 'Incomplete' } else { 'Valid' }
        }
    }
    catch {
        if ($errors.Count -eq 0 -or $errors[-1] -ne [string]$_.Exception.Message) {
            $errors.Add([string]$_.Exception.Message)
        }
        $status = 'Invalid'
    }
    finally {
        if ($null -ne $temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }

    [pscustomobject][ordered]@{
        PackagePath = $resolvedPackage
        Status = $status
        Valid = ($status -eq 'Valid')
        Complete = ($status -eq 'Valid')
        FilesChecked = $filesChecked
        LedgerEntries = $ledgerEntries
        LedgerHead = $ledgerHead
        Errors = @($errors)
        Warnings = @($warnings)
    }
}
