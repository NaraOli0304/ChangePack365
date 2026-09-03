BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'ChangePack365.psd1') -Force
    $script:Tenant = '11111111-2222-4333-8444-555555555555'

    function New-OfflinePackageCase {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$CaseId
        )

        $case = New-CP365Case `
            -CaseId $CaseId `
            -Title 'Offline package verification test' `
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
}

Describe 'Test-CP365CasePackage' {
    It 'is exported by the module manifest' {
        (Get-Command Test-CP365CasePackage -Module ChangePack365).CommandType |
            Should -Be 'Function'
    }

    It 'validates an untampered internal ZIP offline' {
        $case = New-OfflinePackageCase `
            -Root (Join-Path $TestDrive 'valid-root') `
            -CaseId 'OFFLINE-VALID'
        $bundle = Export-CP365Case -CasePath $case.Path

        $result = Test-CP365CasePackage -PackagePath $bundle.FullName

        $result.Status | Should -Be 'Valid'
        $result.Valid | Should -BeTrue
        $result.Complete | Should -BeTrue
        $result.FilesChecked | Should -BeGreaterThan 0
        $result.LedgerEntries | Should -BeGreaterThan 0
        $result.Errors.Count | Should -Be 0
    }

    It 'detects a changed manifest-listed file in an extracted package' {
        $case = New-OfflinePackageCase `
            -Root (Join-Path $TestDrive 'tampered-root') `
            -CaseId 'OFFLINE-TAMPERED'
        $bundle = Export-CP365Case -CasePath $case.Path
        $extractPath = Join-Path $TestDrive 'tampered-extracted'
        Expand-Archive -LiteralPath $bundle.FullName -DestinationPath $extractPath
        Add-Content -LiteralPath (Join-Path $extractPath 'contract.json') -Value ' '

        $result = Test-CP365CasePackage -PackagePath $extractPath

        $result.Status | Should -Be 'Invalid'
        $result.Valid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'mismatch: contract.json'
    }

    It 'detects a file that is absent from the package manifest' {
        $case = New-OfflinePackageCase `
            -Root (Join-Path $TestDrive 'extra-root') `
            -CaseId 'OFFLINE-EXTRA'
        $bundle = Export-CP365Case -CasePath $case.Path
        $extractPath = Join-Path $TestDrive 'extra-extracted'
        Expand-Archive -LiteralPath $bundle.FullName -DestinationPath $extractPath
        'unexpected' | Set-Content -LiteralPath (Join-Path $extractPath 'extra.txt')

        $result = Test-CP365CasePackage -PackagePath $extractPath

        $result.Status | Should -Be 'Invalid'
        ($result.Errors -join ' ') | Should -Match 'Unexpected package file: extra.txt'
    }

    It 'reports an integrity-valid package with incomplete evidence as incomplete' {
        $case = New-OfflinePackageCase `
            -Root (Join-Path $TestDrive 'incomplete-root') `
            -CaseId 'OFFLINE-INCOMPLETE'
        $incompletePath = Join-Path $TestDrive 'collection-manifest_incomplete.json'
        @{
            complete = $false
            slices = @(
                @{
                    complete = $false
                    httpStatus = 503
                    error = 'Synthetic failure.'
                }
            )
        } |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $incompletePath -Encoding utf8
        Add-CP365Evidence `
            -CasePath $case.Path `
            -Phase logs `
            -Path $incompletePath |
            Out-Null
        $bundle = Export-CP365Case -CasePath $case.Path

        $result = Test-CP365CasePackage -PackagePath $bundle.FullName

        $result.Status | Should -Be 'Incomplete'
        $result.Valid | Should -BeFalse
        $result.Complete | Should -BeFalse
        $result.Errors.Count | Should -Be 0
    }

    It 'rejects a public bundle as not independently verifiable' {
        $case = New-OfflinePackageCase `
            -Root (Join-Path $TestDrive 'public-root') `
            -CaseId 'OFFLINE-PUBLIC'
        $bundle = Export-CP365Case -CasePath $case.Path -Public

        $result = Test-CP365CasePackage -PackagePath $bundle.FullName

        $result.Status | Should -Be 'Unsupported'
        $result.Valid | Should -BeFalse
        ($result.Warnings -join ' ') |
            Should -Match 'Public bundles are redacted'
    }

    It 'rejects a ZIP entry that attempts directory traversal' {
        $zipPath = Join-Path $TestDrive 'unsafe.zip'
        $stream = [IO.File]::Open(
            $zipPath,
            [IO.FileMode]::Create,
            [IO.FileAccess]::ReadWrite
        )
        $archive = [IO.Compression.ZipArchive]::new(
            $stream,
            [IO.Compression.ZipArchiveMode]::Create
        )
        try {
            $entry = $archive.CreateEntry('../escape.txt')
            $writer = [IO.StreamWriter]::new($entry.Open())
            try {
                $writer.Write('unsafe')
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            $archive.Dispose()
            $stream.Dispose()
        }

        $result = Test-CP365CasePackage -PackagePath $zipPath

        $result.Status | Should -Be 'Invalid'
        ($result.Errors -join ' ') | Should -Match 'Unsafe ZIP entry path'
    }
}
