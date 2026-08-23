BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ChangePack365.psd1') -Force
    $script:Root = Join-Path $TestDrive 'cases'
    $script:Tenant = '11111111-2222-4333-8444-555555555555'
}

Describe 'ChangePack365 context fingerprint' {
    It 'is stable and changes with the account' {
        $a = Get-CP365ContextFingerprint -TenantId $Tenant -Account 'one@contoso.example'
        $b = Get-CP365ContextFingerprint -TenantId $Tenant -Account 'one@contoso.example'
        $c = Get-CP365ContextFingerprint -TenantId $Tenant -Account 'two@contoso.example'
        $a | Should -Be $b
        $a | Should -Not -Be $c
        $a | Should -Match '^CP365-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}$'
    }
}

Describe 'ChangePack365 ledger' {
    It 'detects tampering' {
        $case = New-CP365Case -CaseId 'TEST-LEDGER' -Title Test -TenantId $Tenant -TenantDisplayName Contoso -Account 'one@contoso.example' -RootPath $Root
        (Test-CP365Ledger -CasePath $case.Path).Valid | Should -BeTrue
        $ledgerPath = Join-Path $case.Path 'ledger.jsonl'
        (Get-Content $ledgerPath -Raw).Replace('CaseCreated', 'CaseChanged') | Set-Content $ledgerPath
        (Test-CP365Ledger -CasePath $case.Path).Valid | Should -BeFalse
    }
}

Describe 'ChangePack365 snapshot contract' {
    It 'classifies expected, unexpected and forbidden deltas' {
        $case = New-CP365Case -CaseId 'TEST-DIFF' -Title Test -TenantId $Tenant -TenantDisplayName Contoso -Account 'one@contoso.example' -RootPath $Root `
            -ExpectedChange @(@{ path = '$.allowed'; operation = 'Modified' }) `
            -ForbiddenChange @(@{ path = '$.blocked'; operation = 'Modified' })
        @{ allowed = 1; blocked = 1; surprise = 1 } | ConvertTo-Json | Set-Content (Join-Path $TestDrive 'before.json')
        @{ allowed = 2; blocked = 2; surprise = 2 } | ConvertTo-Json | Set-Content (Join-Path $TestDrive 'after.json')
        $result = Compare-CP365Snapshot -CasePath $case.Path -BeforePath (Join-Path $TestDrive 'before.json') -AfterPath (Join-Path $TestDrive 'after.json')
        $result.Summary.expected | Should -Be 1
        $result.Summary.forbidden | Should -Be 1
        $result.Summary.unexpected | Should -Be 1

        $summaries = @(New-CP365StakeholderSummary -CasePath $case.Path)
        $summaries.Count | Should -Be 3
        $summaries.Decision | Should -Contain 'STOP'
        Test-Path (Join-Path $case.Path 'public/summary-pt-BR.md') | Should -BeTrue

        $report = Export-CP365HtmlReport -CasePath $case.Path
        $report.Exists | Should -BeTrue
        (Get-Content -LiteralPath $report.FullName -Raw) | Should -Match 'CP365-'
        (Get-Content -LiteralPath $report.FullName -Raw) | Should -Match 'Cadeia de integridade verificada'

        Add-CP365Evidence -CasePath $case.Path -Phase before -Path (Join-Path $TestDrive 'before.json') | Out-Null
        Add-CP365Evidence -CasePath $case.Path -Phase after -Path (Join-Path $TestDrive 'after.json') | Out-Null
        $internal = Export-CP365Case -CasePath $case.Path
        $public = Export-CP365Case -CasePath $case.Path -Public
        $internal.Exists | Should -BeTrue
        $public.Exists | Should -BeTrue
        (Test-CP365Ledger -CasePath $case.Path).Valid | Should -BeTrue
    }
}
