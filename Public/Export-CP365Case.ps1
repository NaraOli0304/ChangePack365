function Export-CP365Case {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$CasePath,
        [string]$OutputPath,
        [switch]$Public,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$SigningCertificate
    )

    if ($null -ne $SigningCertificate) {
        if (-not $SigningCertificate.HasPrivateKey) {
            throw 'SigningCertificate must include a private key.'
        }

        $now = [datetime]::UtcNow
        if ($now -lt $SigningCertificate.NotBefore.ToUniversalTime() -or
            $now -gt $SigningCertificate.NotAfter.ToUniversalTime()) {
            throw 'SigningCertificate is not currently valid.'
        }
    }

    $context = Get-CP365CaseContext -CasePath $CasePath
    $ledger = Test-CP365Ledger -CasePath $context.Root
    if (-not $ledger.Valid) { throw "Ledger validation failed: $($ledger.Errors -join ' ')" }
    $output = if ($OutputPath) { $OutputPath } else { Join-Path $context.Root 'artifacts' }
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $stage = Join-Path ([IO.Path]::GetTempPath()) "cp365-$([guid]::NewGuid().Guid)"
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        $salt = (Get-Content -LiteralPath (Join-Path $context.Root '.redaction-salt') -Raw).Trim()
        $excludedRoots = if ($Public) {
            @('artifacts')
        } else {
            @('artifacts', 'public')
        }
        $files = Get-ChildItem -LiteralPath $context.Root -File -Recurse | Where-Object {
            $relative = [IO.Path]::GetRelativePath($context.Root, $_.FullName)
            ($relative -ne '.redaction-salt') -and ($excludedRoots -notcontains ($relative -split '[\\/]')[0])
        }
        $kind = if ($Public) { 'public' } else { 'internal' }
        $manifest = [System.Collections.Generic.List[object]]::new()
        foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($context.Root, $file.FullName)
            $destination = Join-Path $stage $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            if ($Public -and $file.Extension -in @('.json', '.jsonl', '.csv', '.md', '.txt', '.ps1', '.html')) {
                Protect-CP365Text -Text (Get-Content -LiteralPath $file.FullName -Raw) -Salt $salt | Set-Content -LiteralPath $destination -Encoding utf8
            } else {
                Copy-Item -LiteralPath $file.FullName -Destination $destination
            }
            $manifest.Add([pscustomobject]@{
                path = $relative.Replace('\', '/')
                sha256 = Get-CP365Hash -Path $destination
                bytes = (Get-Item $destination).Length
            })
        }

        $signerThumbprint = if ($null -ne $SigningCertificate) {
            $SigningCertificate.Thumbprint.Replace(' ', '').ToUpperInvariant()
        }
        else {
            $null
        }
        $bundleMetadata = [ordered]@{
            formatVersion = 1
            kind = $kind
            caseId = [string]$context.Contract.caseId
            ledgerHead = [string]$ledger.HeadHash
            signature = if ($null -ne $SigningCertificate) {
                [ordered]@{
                    format = 'CMS/PKCS7'
                    file = 'manifest.p7s'
                    digestAlgorithm = 'SHA256'
                    signerThumbprint = $signerThumbprint
                }
            }
            else {
                $null
            }
        }
        $bundlePath = Join-Path $stage 'bundle.json'
        $bundleMetadata |
            ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $bundlePath -Encoding utf8
        $manifest.Add([pscustomobject]@{
            path = 'bundle.json'
            sha256 = Get-CP365Hash -Path $bundlePath
            bytes = (Get-Item $bundlePath).Length
        })

        $manifestPath = Join-Path $stage 'manifest.json'
        $manifest |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $manifestPath -Encoding utf8

        if ($null -ne $SigningCertificate) {
            Add-Type -AssemblyName System.Security.Cryptography.Pkcs
            $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
            $contentInfo = [System.Security.Cryptography.Pkcs.ContentInfo]::new($manifestBytes)
            $signedCms = [System.Security.Cryptography.Pkcs.SignedCms]::new($contentInfo, $true)
            $cmsSigner = [System.Security.Cryptography.Pkcs.CmsSigner]::new($SigningCertificate)
            $cmsSigner.DigestAlgorithm = [Security.Cryptography.Oid]::new(
                '2.16.840.1.101.3.4.2.1'
            )
            $signedCms.ComputeSignature($cmsSigner, $true)
            [IO.File]::WriteAllBytes(
                (Join-Path $stage 'manifest.p7s'),
                $signedCms.Encode()
            )
        }

        $zip = Join-Path $output "$($context.Contract.caseId)-$kind.zip"
        if ($PSCmdlet.ShouldProcess($zip, 'Export ChangePack365 bundle')) {
            if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
            Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
            Write-CP365LedgerEvent -CasePath $context.Root -EventType 'CaseExported' -Payload @{ kind = $kind; file = Split-Path -Leaf $zip; sha256 = Get-CP365Hash -Path $zip; ledgerHead = $ledger.HeadHash } | Out-Null
            Get-Item $zip
        }
    } finally {
        if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}
