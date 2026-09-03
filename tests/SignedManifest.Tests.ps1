BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'ChangePack365.psd1') -Force
    $script:Tenant = '11111111-2222-4333-8444-555555555555'

    function New-SignedManifestCase {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$CaseId
        )

        $case = New-CP365Case `
            -CaseId $CaseId `
            -Title 'Signed manifest test' `
            -TenantId $script:Tenant `
            -TenantDisplayName 'Contoso Test' `
            -Account 'operator@contoso.example' `
            -RootPath $Root

        $evidencePath = Join-Path $Root "$CaseId-evidence.json"
        @{ id = 'fictional-event'; state = 'complete' } |
            ConvertTo-Json |
            Set-Content -LiteralPath $evidencePath -Encoding utf8
        Add-CP365Evidence `
            -CasePath $case.Path `
            -Phase logs `
            -Path $evidencePath |
            Out-Null

        return $case
    }

    function New-SigningCertificate {
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=ChangePack365 Test Signer',
            $rsa,
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        return $request.CreateSelfSigned(
            [datetimeoffset]::UtcNow.AddMinutes(-5),
            [datetimeoffset]::UtcNow.AddDays(1)
        )
    }
}

Describe 'ChangePack365 signed manifests' {
    It 'verifies a detached signature against the expected signer thumbprint' {
        $certificate = New-SigningCertificate
        try {
            $case = New-SignedManifestCase `
                -Root (Join-Path $TestDrive 'signed-root') `
                -CaseId 'SIGNED-VALID'
            $bundle = Export-CP365Case `
                -CasePath $case.Path `
                -SigningCertificate $certificate

            $result = Test-CP365CasePackage `
                -PackagePath $bundle.FullName `
                -ExpectedSignerThumbprint $certificate.Thumbprint

            $result.Status | Should -Be 'Valid'
            $result.SignatureStatus | Should -Be 'Valid'
            $result.SignerThumbprint | Should -Be $certificate.Thumbprint
            $result.SignerSubject | Should -Be $certificate.Subject
            $result.AuthenticityEstablished | Should -BeTrue
            $result.Errors.Count | Should -Be 0
        }
        finally {
            $certificate.Dispose()
        }
    }

    It 'does not claim signer identity without an expected thumbprint' {
        $certificate = New-SigningCertificate
        try {
            $case = New-SignedManifestCase `
                -Root (Join-Path $TestDrive 'unanchored-root') `
                -CaseId 'SIGNED-UNANCHORED'
            $bundle = Export-CP365Case `
                -CasePath $case.Path `
                -SigningCertificate $certificate

            $result = Test-CP365CasePackage -PackagePath $bundle.FullName

            $result.Status | Should -Be 'Valid'
            $result.SignatureStatus | Should -Be 'Valid'
            $result.AuthenticityEstablished | Should -BeFalse
            ($result.Warnings -join ' ') |
                Should -Match 'not anchored with an expected thumbprint'
        }
        finally {
            $certificate.Dispose()
        }
    }

    It 'rejects a signer that differs from the expected thumbprint' {
        $certificate = New-SigningCertificate
        try {
            $case = New-SignedManifestCase `
                -Root (Join-Path $TestDrive 'wrong-signer-root') `
                -CaseId 'SIGNED-WRONG-SIGNER'
            $bundle = Export-CP365Case `
                -CasePath $case.Path `
                -SigningCertificate $certificate

            $result = Test-CP365CasePackage `
                -PackagePath $bundle.FullName `
                -ExpectedSignerThumbprint ('A' * 40)

            $result.Status | Should -Be 'Invalid'
            $result.SignatureStatus | Should -Be 'ExpectedSignerMismatch'
            $result.AuthenticityEstablished | Should -BeFalse
        }
        finally {
            $certificate.Dispose()
        }
    }

    It 'detects a manifest changed after signing' {
        $certificate = New-SigningCertificate
        try {
            $case = New-SignedManifestCase `
                -Root (Join-Path $TestDrive 'changed-root') `
                -CaseId 'SIGNED-CHANGED'
            $bundle = Export-CP365Case `
                -CasePath $case.Path `
                -SigningCertificate $certificate
            $extractPath = Join-Path $TestDrive 'changed-extracted'
            Expand-Archive `
                -LiteralPath $bundle.FullName `
                -DestinationPath $extractPath
            Add-Content `
                -LiteralPath (Join-Path $extractPath 'manifest.json') `
                -Value ' '

            $result = Test-CP365CasePackage `
                -PackagePath $extractPath `
                -ExpectedSignerThumbprint $certificate.Thumbprint

            $result.Status | Should -Be 'Invalid'
            $result.SignatureStatus | Should -Be 'Invalid'
            ($result.Errors -join ' ') |
                Should -Match 'Manifest signature'
        }
        finally {
            $certificate.Dispose()
        }
    }

    It 'rejects an unsigned package when a signer is expected' {
        $case = New-SignedManifestCase `
            -Root (Join-Path $TestDrive 'unsigned-root') `
            -CaseId 'SIGNED-MISSING'
        $bundle = Export-CP365Case -CasePath $case.Path

        $result = Test-CP365CasePackage `
            -PackagePath $bundle.FullName `
            -ExpectedSignerThumbprint ('B' * 40)

        $result.Status | Should -Be 'Invalid'
        $result.SignatureStatus | Should -Be 'Missing'
        ($result.Errors -join ' ') |
            Should -Match 'requires a signed manifest'
    }

    It 'refuses a signing certificate without a private key' {
        $certificate = New-SigningCertificate
        try {
            $publicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
                $certificate.Export(
                    [Security.Cryptography.X509Certificates.X509ContentType]::Cert
                )
            )
            try {
                $case = New-SignedManifestCase `
                    -Root (Join-Path $TestDrive 'public-key-root') `
                    -CaseId 'SIGNED-NO-PRIVATE-KEY'

                {
                    Export-CP365Case `
                        -CasePath $case.Path `
                        -SigningCertificate $publicCertificate
                } | Should -Throw '*must include a private key*'
            }
            finally {
                $publicCertificate.Dispose()
            }
        }
        finally {
            $certificate.Dispose()
        }
    }
}
