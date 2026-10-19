BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../ChangePack365.psd1') -Force
}

Describe 'Snapshot comparison result cardinality' {
    It 'persists a valid comparison containing <Count> differences' -ForEach @(
        @{ Count = 0; AfterJson = '{"first":1,"second":1}' }
        @{ Count = 1; AfterJson = '{"first":2,"second":1}' }
        @{ Count = 2; AfterJson = '{"first":2,"second":2}' }
    ) {
        $case = New-CP365Case -CaseId "DIFF-COUNT-$Count" -Title 'Comparison cardinality' -TenantId '11111111-2222-4333-8444-555555555555' -TenantDisplayName 'Contoso' -Account 'operator@contoso.example' -RootPath $TestDrive
        $beforePath = Join-Path $TestDrive "before-$Count.json"
        $afterPath = Join-Path $TestDrive "after-$Count.json"
        Set-Content -LiteralPath $beforePath -Value '{"first":1,"second":1}' -Encoding utf8
        Set-Content -LiteralPath $afterPath -Value $AfterJson -Encoding utf8

        $result = Compare-CP365Snapshot -CasePath $case.Path -BeforePath $beforePath -AfterPath $afterPath

        $result.Summary.total | Should -Be $Count
        $result.Summary.expected | Should -Be 0
        $result.Summary.unexpected | Should -Be $Count
        $result.Summary.forbidden | Should -Be 0
        @($result.Changes).Count | Should -Be $Count
        Test-Path -LiteralPath $result.CsvPath | Should -BeTrue
        $json = Get-Content -LiteralPath $result.JsonPath -Raw
        $json.TrimStart().StartsWith('[') | Should -BeTrue
        $parsed = ConvertFrom-Json -InputObject $json -NoEnumerate
        ($parsed -is [array]) | Should -BeTrue
        $parsed.Count | Should -Be $Count
        $result.Summary.diffHash | Should -Be (Get-FileHash -LiteralPath $result.JsonPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $events = @(Get-Content -LiteralPath (Join-Path $case.Path 'ledger.jsonl') | ConvertFrom-Json)
        $comparisons = @($events | Where-Object eventType -eq 'SnapshotsCompared')
        $comparisons.Count | Should -Be 1
        $comparisons[0].payload.total | Should -Be $Count
        $comparisons[0].payload.diffHash | Should -Be $result.Summary.diffHash
        (Test-CP365Ledger -CasePath $case.Path).Valid | Should -BeTrue
    }
}
