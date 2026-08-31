BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'ChangePack365.psd1') -Force

    function New-TestCollectorManifest {
        param(
            [Parameter(Mandatory)][string]$Root,
            [switch]$Incomplete,
            [switch]$OmitCheckpointHash,
            [string]$CheckpointRoot
        )

        $null = New-Item -ItemType Directory -Path $Root -Force
        if ([string]::IsNullOrWhiteSpace($CheckpointRoot)) {
            $CheckpointRoot = $Root
        }
        $null = New-Item -ItemType Directory -Path $CheckpointRoot -Force

        $checkpointPath = Join-Path $CheckpointRoot 'slice_0123456789abcdef_20260101-000000_20260101-001500.jsonl'
        @(
            '{"id":"evt-1","createdDateTime":"2026-01-01T00:01:00Z"}',
            '{"id":"evt-2","createdDateTime":"2026-01-01T00:02:00Z"}'
        ) | Set-Content -LiteralPath $checkpointPath -Encoding utf8

        $checkpointHash = (
            Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        $completeSlice = [ordered]@{
            queryFingerprint = '0123456789abcdef'
            startUtc = '2026-01-01T00:00:00.0000000Z'
            endUtc = '2026-01-01T00:15:00.0000000Z'
            windowMinutes = 15
            complete = $true
            recordCount = 2
            pageCount = 1
            requestCount = 1
            checkpoint = $checkpointPath
        }
        if (-not $OmitCheckpointHash) {
            $completeSlice.checkpointSha256 = $checkpointHash
        }

        $slices = @([pscustomobject]$completeSlice)
        if ($Incomplete) {
            $slices += [pscustomobject][ordered]@{
                queryFingerprint = '0123456789abcdef'
                startUtc = '2026-01-01T00:15:00.0000000Z'
                endUtc = '2026-01-01T00:30:00.0000000Z'
                windowMinutes = 15
                complete = $false
                pageCount = 0
                requestCount = 1
                httpStatus = 503
                error = 'Synthetic transient failure.'
            }
        }

        $manifest = [ordered]@{
            collectedAtUtc = '2026-01-01T01:00:00.0000000Z'
            queryMode = 'GET_ONLY'
            queryFingerprint = '0123456789abcdef'
            baseUri = 'https://graph.microsoft.com/v1.0/auditLogs/signIns'
            dateProperty = 'createdDateTime'
            select = 'id,createdDateTime'
            additionalFilter = $null
            identityProperty = 'id'
            startUtc = '2026-01-01T00:00:00.0000000Z'
            endUtc = if ($Incomplete) {
                '2026-01-01T00:30:00.0000000Z'
            } else {
                '2026-01-01T00:15:00.0000000Z'
            }
            complete = -not $Incomplete
            uniqueRecordCount = 2
            sliceCount = $slices.Count
            slices = $slices
        }

        $manifestPath = Join-Path $Root 'collection-manifest_0123456789abcdef.json'
        $manifest |
            ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $manifestPath -Encoding utf8

        [pscustomobject]@{
            ManifestPath = $manifestPath
            CheckpointPath = $checkpointPath
            CheckpointHash = $checkpointHash
        }
    }
}

Describe 'New-CP365GraphEvidenceRecord' {
    It 'is exported by the module manifest' {
        $command = Get-Command `
            -Name 'New-CP365GraphEvidenceRecord' `
            -Module 'ChangePack365' `
            -ErrorAction Stop

        $command.CommandType | Should -Be 'Function'
    }

    It 'writes a normalized record after verifying every complete checkpoint' {
        $fixture = New-TestCollectorManifest -Root (Join-Path $TestDrive 'complete')
        $result = New-CP365GraphEvidenceRecord `
            -ManifestPath $fixture.ManifestPath `
            -Collection 'SignInLogs' `
            -TenantFingerprint 'CP365-AAAA-BBBB-CCCC' `
            -AccountFingerprint 'CP365-DDDD-EEEE-FFFF'

        Test-Path -LiteralPath $result.Path | Should -BeTrue
        $recordJson = Get-Content -LiteralPath $result.Path -Raw
        $recordJson | Test-Json | Should -BeTrue
        $record = $recordJson | ConvertFrom-Json -Depth 20

        $requiredProperties = @(
            'artifactPath',
            'collectedAtUtc',
            'collection',
            'complete',
            'evidenceId',
            'queryMode',
            'sha256',
            'source'
        )
        foreach ($property in $requiredProperties) {
            $record.PSObject.Properties.Name | Should -Contain $property
        }

        $record.evidenceId | Should -Match '^graph-[a-f0-9]{20}$'
        $record.source | Should -Be 'MicrosoftGraph'
        $record.collection | Should -Be 'SignInLogs'
        $record.queryMode | Should -Be 'GET_ONLY'
        $record.complete | Should -BeTrue
        $record.completenessNote | Should -BeNullOrEmpty
        $record.recordCount | Should -Be 2
        $record.sha256 | Should -Match '^[a-f0-9]{64}$'
        $record.sha256 | Should -Be (
            Get-FileHash -LiteralPath $fixture.ManifestPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $record.metadata.queryFingerprint | Should -Be '0123456789abcdef'
        $record.metadata.incompleteSliceCount | Should -Be 0
        $record.notes[0] | Should -Be 'Verified 1 checkpoint hash(es).'
    }

    It 'fails closed when a checkpoint changes after the manifest is written' {
        $fixture = New-TestCollectorManifest -Root (Join-Path $TestDrive 'tampered')
        Add-Content -LiteralPath $fixture.CheckpointPath -Value '{"id":"tampered"}'

        {
            New-CP365GraphEvidenceRecord `
                -ManifestPath $fixture.ManifestPath `
                -Collection 'SignInLogs'
        } | Should -Throw '*Checkpoint hash mismatch*'

        Test-Path (
            Join-Path (Split-Path -Parent $fixture.ManifestPath) 'evidence-record_0123456789abcdef.json'
        ) | Should -BeFalse
    }

    It 'rejects a complete slice without a checkpoint hash' {
        $fixture = New-TestCollectorManifest `
            -Root (Join-Path $TestDrive 'missing-hash') `
            -OmitCheckpointHash

        {
            New-CP365GraphEvidenceRecord `
                -ManifestPath $fixture.ManifestPath `
                -Collection 'SignInLogs'
        } | Should -Throw '*checkpointSha256*'
    }

    It 'preserves an incomplete collection instead of presenting it as success' {
        $fixture = New-TestCollectorManifest `
            -Root (Join-Path $TestDrive 'incomplete') `
            -Incomplete

        $result = New-CP365GraphEvidenceRecord `
            -ManifestPath $fixture.ManifestPath `
            -Collection 'SignInLogs'

        $record = Get-Content -LiteralPath $result.Path -Raw |
            ConvertFrom-Json -Depth 20

        $record.complete | Should -BeFalse
        $record.completenessNote | Should -Be 'Collector manifest reports 1 incomplete slice(s).'
        $record.metadata.incompleteSliceCount | Should -Be 1
        $record.notes[0] | Should -Be 'Verified 1 checkpoint hash(es).'
    }

    It 'rejects checkpoints outside the manifest directory' {
        $fixture = New-TestCollectorManifest `
            -Root (Join-Path $TestDrive 'confined') `
            -CheckpointRoot (Join-Path $TestDrive 'outside')

        {
            New-CP365GraphEvidenceRecord `
                -ManifestPath $fixture.ManifestPath `
                -Collection 'SignInLogs'
        } | Should -Throw '*inside the manifest directory*'
    }
}
