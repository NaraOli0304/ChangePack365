BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'ChangePack365.psd1') -Force
    $script:Tenant = '11111111-2222-4333-8444-555555555555'

    function New-RegistrationFixture {
        param(
            [Parameter(Mandatory)][string]$Root,
            [switch]$Incomplete
        )

        $null = New-Item -ItemType Directory -Path $Root -Force
        $checkpointPath = Join-Path $Root 'slice.jsonl'
        '{"id":"evt-1","createdDateTime":"2026-01-01T00:01:00Z"}' |
            Set-Content -LiteralPath $checkpointPath -Encoding utf8
        $checkpointHash = (Get-FileHash $checkpointPath -Algorithm SHA256).Hash.ToLowerInvariant()

        $slices = @([pscustomobject][ordered]@{
            complete = $true
            checkpoint = $checkpointPath
            checkpointSha256 = $checkpointHash
            recordCount = 1
        })
        if ($Incomplete) {
            $slices += [pscustomobject][ordered]@{
                complete = $false
                httpStatus = 503
                error = 'Synthetic failure.'
            }
        }

        $manifest = [ordered]@{
            complete = -not $Incomplete
            slices = $slices
        }
        $manifestPath = Join-Path $Root 'collection-manifest.json'
        $manifest | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $manifestPath -Encoding utf8
        $manifestHash = (Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()

        $record = [ordered]@{
            evidenceId = 'graph-0123456789abcdef0123'
            source = 'MicrosoftGraph'
            collection = 'SignInLogs'
            collectedAtUtc = '2026-01-01T01:00:00Z'
            queryMode = 'GET_ONLY'
            complete = -not $Incomplete
            artifactPath = 'collection-manifest.json'
            sha256 = $manifestHash
        }
        $recordPath = Join-Path $Root 'evidence-record.json'
        $record | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $recordPath -Encoding utf8

        [pscustomobject]@{
            RecordPath = $recordPath
            ManifestPath = $manifestPath
            CheckpointPath = $checkpointPath
        }
    }

    function New-RegistrationCase {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$CaseId)

        New-CP365Case `
            -CaseId $CaseId `
            -Title 'Graph evidence registration test' `
            -TenantId $script:Tenant `
            -TenantDisplayName 'Contoso' `
            -Account 'operator@contoso.example' `
            -RootPath $Root
    }
}

Describe 'Add-CP365GraphEvidenceRecord' {
    It 'is exported by the module manifest' {
        (Get-Command Add-CP365GraphEvidenceRecord -Module ChangePack365).CommandType |
            Should -Be 'Function'
    }

    It 'registers a portable record, manifest, and checkpoints in the ledger' {
        $fixture = New-RegistrationFixture -Root (Join-Path $TestDrive 'source')
        $case = New-RegistrationCase -Root (Join-Path $TestDrive 'cases') -CaseId 'GRAPH-REGISTER'

        $result = Add-CP365GraphEvidenceRecord `
            -CasePath $case.Path `
            -RecordPath $fixture.RecordPath

        Test-Path $result.RecordPath | Should -BeTrue
        Test-Path $result.ManifestPath | Should -BeTrue
        $result.CheckpointPaths.Count | Should -Be 1
        Test-Path $result.CheckpointPaths[0] | Should -BeTrue
        $result.Complete | Should -BeTrue

        $portableRecord = Get-Content $result.RecordPath -Raw | ConvertFrom-Json
        $portableManifest = Get-Content $result.ManifestPath -Raw | ConvertFrom-Json
        $portableRecord.artifactPath | Should -Be 'graph-0123456789abcdef0123-manifest.json'
        $portableRecord.sha256 | Should -Be (
            Get-FileHash $result.ManifestPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $portableManifest.slices[0].checkpoint |
            Should -Be 'graph-0123456789abcdef0123-checkpoint-0001-slice.jsonl'

        $ledger = Get-Content (Join-Path $case.Path 'ledger.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -Depth 100 }
        $ledger[-1].eventType | Should -Be 'GraphEvidenceRegistered'
        $ledger[-1].payload.complete | Should -BeTrue
        $ledger[-1].payload.checkpointCount | Should -Be 1
        $ledger[-1].payload.recordSha256 | Should -Be (
            Get-FileHash $result.RecordPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $ledger[-1].payload.manifestSha256 | Should -Be (
            Get-FileHash $result.ManifestPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        (Test-CP365Ledger -CasePath $case.Path).Valid | Should -BeTrue
    }

    It 'preserves incomplete collection state' {
        $fixture = New-RegistrationFixture `
            -Root (Join-Path $TestDrive 'incomplete-source') `
            -Incomplete
        $case = New-RegistrationCase -Root (Join-Path $TestDrive 'incomplete-cases') -CaseId 'GRAPH-INCOMPLETE'

        $result = Add-CP365GraphEvidenceRecord `
            -CasePath $case.Path `
            -RecordPath $fixture.RecordPath

        $result.Complete | Should -BeFalse
        (Get-Content $result.RecordPath -Raw | ConvertFrom-Json).complete |
            Should -BeFalse
    }

    It 'fails before writing when the manifest changed' {
        $fixture = New-RegistrationFixture -Root (Join-Path $TestDrive 'tampered-source')
        $case = New-RegistrationCase -Root (Join-Path $TestDrive 'tampered-cases') -CaseId 'GRAPH-TAMPERED'
        Add-Content -LiteralPath $fixture.ManifestPath -Value ' '

        {
            Add-CP365GraphEvidenceRecord `
                -CasePath $case.Path `
                -RecordPath $fixture.RecordPath
        } | Should -Throw '*manifest hash*'

        (Get-ChildItem (Join-Path $case.Path 'artifacts') -File).Count |
            Should -Be 0
    }

    It 'fails before writing when a checkpoint changed' {
        $fixture = New-RegistrationFixture -Root (Join-Path $TestDrive 'checkpoint-tampered-source')
        $case = New-RegistrationCase -Root (Join-Path $TestDrive 'checkpoint-tampered-cases') -CaseId 'GRAPH-CHECKPOINT-TAMPERED'
        Add-Content -LiteralPath $fixture.CheckpointPath -Value '{"id":"tampered"}'

        {
            Add-CP365GraphEvidenceRecord `
                -CasePath $case.Path `
                -RecordPath $fixture.RecordPath
        } | Should -Throw '*Checkpoint hash mismatch*'

        (Get-ChildItem (Join-Path $case.Path 'artifacts') -File).Count |
            Should -Be 0
    }

    It 'rejects an artifact path outside the record directory' {
        $fixture = New-RegistrationFixture -Root (Join-Path $TestDrive 'escaped-source')
        $case = New-RegistrationCase -Root (Join-Path $TestDrive 'escaped-cases') -CaseId 'GRAPH-ESCAPED'
        $record = Get-Content $fixture.RecordPath -Raw | ConvertFrom-Json
        $record.artifactPath = '../collection-manifest.json'
        $record | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $fixture.RecordPath -Encoding utf8

        {
            Add-CP365GraphEvidenceRecord `
                -CasePath $case.Path `
                -RecordPath $fixture.RecordPath
        } | Should -Throw '*must remain inside*'

        (Get-ChildItem (Join-Path $case.Path 'artifacts') -File).Count |
            Should -Be 0
    }

    It 'refuses to overwrite a previously registered evidence set' {
        $fixture = New-RegistrationFixture -Root (Join-Path $TestDrive 'duplicate-source')
        $case = New-RegistrationCase -Root (Join-Path $TestDrive 'duplicate-cases') -CaseId 'GRAPH-DUPLICATE'
        Add-CP365GraphEvidenceRecord -CasePath $case.Path -RecordPath $fixture.RecordPath | Out-Null
        $entriesBefore = (Get-Content (Join-Path $case.Path 'ledger.jsonl')).Count

        {
            Add-CP365GraphEvidenceRecord `
                -CasePath $case.Path `
                -RecordPath $fixture.RecordPath
        } | Should -Throw '*will not be overwritten*'

        (Get-Content (Join-Path $case.Path 'ledger.jsonl')).Count |
            Should -Be $entriesBefore
    }
}
