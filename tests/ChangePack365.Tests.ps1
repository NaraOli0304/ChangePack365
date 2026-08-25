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

Describe 'Conditional Access Graph adapter' {
    BeforeEach {
        function global:Get-MgContext {
            [pscustomobject]@{
                TenantId = $script:Tenant
                Account = 'one@contoso.example'
                AuthType = 'Delegated'
                Scopes = @('Policy.Read.All')
            }
        }
        function global:Invoke-MgGraphRequest {
            param([string]$Method, [string]$Uri)
            if ($Uri -eq '/v1.0/identity/conditionalAccess/policies') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; displayName = 'Policy B'; state = 'enabled' })
                    '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/next-page'
                }
            }
            [pscustomobject]@{
                value = @([pscustomobject]@{ id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; displayName = 'Policy A'; state = 'disabled' })
            }
        }
    }

    AfterEach {
        Remove-Item Function:\Get-MgContext -ErrorAction SilentlyContinue
        Remove-Item Function:\Invoke-MgGraphRequest -ErrorAction SilentlyContinue
    }

    It 'collects every page and records read-only evidence in deterministic order' {
        $case = New-CP365Case -CaseId 'TEST-GRAPH' -Title Test -TenantId $Tenant -TenantDisplayName Contoso -Account 'one@contoso.example' -RootPath $Root
        $result = Save-CP365ConditionalAccessSnapshot -CasePath $case.Path -Phase before
        $result.PolicyCount | Should -Be 2
        $result.ReadOnly | Should -BeTrue
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        $snapshot = Get-Content -LiteralPath $result.Path -Raw | ConvertFrom-Json -Depth 100
        $snapshot.policies[0].displayName | Should -Be 'Policy A'
        (Test-CP365Ledger -CasePath $case.Path).Valid | Should -BeTrue
    }

    It 'rejects a different connected tenant before calling Graph' {
        $case = New-CP365Case -CaseId 'TEST-GRAPH-MISMATCH' -Title Test -TenantId $Tenant -TenantDisplayName Contoso -Account 'one@contoso.example' -RootPath $Root
        function global:Get-MgContext {
            [pscustomobject]@{ TenantId = '99999999-2222-4333-8444-555555555555'; Account = 'one@contoso.example'; AuthType = 'Delegated'; Scopes = @('Policy.Read.All') }
        }
        { Save-CP365ConditionalAccessSnapshot -CasePath $case.Path -Phase before } | Should -Throw '*tenant mismatch*'
    }
}

Describe 'ChangePack365 public bundle' {
    It 'includes redacted stakeholder reports and portable manifest paths' {
        $tenantId = '11111111-2222-4333-8444-555555555555'
        $account = 'operator@contoso.example'
        $sourceIp = '192.0.2.10'
        $root = Join-Path $TestDrive 'public-bundle'

        $expected = @(
            @{
                path = '$.policy.state'
                operation = 'Modified'
                description = 'Enable the pilot policy'
            }
        )

        $case = New-CP365Case `
            -CaseId 'PUBLIC-BUNDLE-TEST' `
            -Title 'Public bundle test' `
            -TenantId $tenantId `
            -TenantDisplayName 'Contoso Test' `
            -Account $account `
            -Workload EntraID `
            -Mode ReadOnly `
            -ExpectedChange $expected `
            -ForbiddenChange @() `
            -RootPath $root

        $beforeInput = Join-Path $TestDrive 'before-input.json'
        $afterInput = Join-Path $TestDrive 'after-input.json'

        @{
            policy = @{
                state = 'reportOnly'
            }
        } |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $beforeInput

        @{
            policy = @{
                state = 'enabled'
            }
            metadata = @{
                operator = $account
                sourceIp = $sourceIp
            }
        } |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $afterInput

        Add-CP365Evidence `
            -CasePath $case.Path `
            -Phase before `
            -Path $beforeInput |
            Out-Null

        Add-CP365Evidence `
            -CasePath $case.Path `
            -Phase after `
            -Path $afterInput |
            Out-Null

        Compare-CP365Snapshot `
            -CasePath $case.Path `
            -BeforePath $beforeInput `
            -AfterPath $afterInput |
            Out-Null

        New-CP365StakeholderSummary `
            -CasePath $case.Path |
            Out-Null

        Export-CP365HtmlReport `
            -CasePath $case.Path `
            -Language 'pt-BR' |
            Out-Null

        $bundle = Export-CP365Case `
            -CasePath $case.Path `
            -Public

        $extractPath = Join-Path $TestDrive 'public-extracted'

        Expand-Archive `
            -LiteralPath $bundle.FullName `
            -DestinationPath $extractPath

        @(
            'change-report.html',
            'summary-en.md',
            'summary-pt-BR.md',
            'summary-es.md'
        ) |
            ForEach-Object {
                Test-Path (
                    Join-Path $extractPath "public/$_"
                ) |
                    Should -BeTrue
            }

        Test-Path (
            Join-Path $extractPath '.redaction-salt'
        ) |
            Should -BeFalse

        $publishedText = (
            Get-ChildItem $extractPath -File -Recurse |
            Where-Object Extension -In @(
                '.json',
                '.jsonl',
                '.csv',
                '.md',
                '.html'
            ) |
            ForEach-Object {
                Get-Content $_.FullName -Raw
            }
        ) -join "`n"

        $publishedText |
            Should -Not -Match ([regex]::Escape($tenantId))

        $publishedText |
            Should -Not -Match ([regex]::Escape($account))

        $publishedText |
            Should -Not -Match ([regex]::Escape($sourceIp))

        $manifest = Get-Content `
            (Join-Path $extractPath 'manifest.json') `
            -Raw |
            ConvertFrom-Json

        $manifestPaths = @($manifest.path)

        $manifestPaths |
            Should -Contain 'public/change-report.html'

        ($manifestPaths -join "`n") |
            Should -Not -Match '\\'
    }
}
