param([string]$OutputRoot = (Join-Path $PSScriptRoot '..\demo-output'))

$module = Join-Path $PSScriptRoot '..\ChangePack365.psd1'
Import-Module $module -Force

$tenantId = '11111111-2222-4333-8444-555555555555'
$expected = @(@{ path = '$.policies.PilotPolicy.state'; operation = 'Modified'; description = 'Move pilot policy from report-only to enabled' })
$forbidden = @(@{ path = '$.policies.BreakGlass*'; description = 'Emergency access policy must not change' })
$caseId = "DEMO-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
$case = New-CP365Case -CaseId $caseId -Title 'Conditional Access pilot change' `
    -TenantId $tenantId -TenantDisplayName 'Contoso Demo' -Account 'operator@contoso.example' `
    -Workload EntraID -Mode ReadOnly -ExpectedChange $expected -ForbiddenChange $forbidden -RootPath $OutputRoot

$before = @{ policies = @{ PilotPolicy = @{ state = 'enabledForReportingButNotEnforced'; users = @('pilot-group') }; BreakGlass = @{ state = 'enabled' } } }
$after  = @{ policies = @{ PilotPolicy = @{ state = 'enabled'; users = @('pilot-group') }; BreakGlass = @{ state = 'enabled' } }; metadata = @{ operator = 'operator@contoso.example'; sourceIp = '192.0.2.10' } }
$beforePath = Join-Path $OutputRoot 'before.json'; $afterPath = Join-Path $OutputRoot 'after.json'
$before | ConvertTo-Json -Depth 10 | Set-Content $beforePath
$after | ConvertTo-Json -Depth 10 | Set-Content $afterPath

Add-CP365Evidence -CasePath $case.Path -Phase before -Path $beforePath | Out-Null
Add-CP365Evidence -CasePath $case.Path -Phase after -Path $afterPath | Out-Null
$diff = Compare-CP365Snapshot -CasePath $case.Path -BeforePath $beforePath -AfterPath $afterPath
$summaries = @(New-CP365StakeholderSummary -CasePath $case.Path)
$report = Export-CP365HtmlReport -CasePath $case.Path
$internal = Export-CP365Case -CasePath $case.Path
$public = Export-CP365Case -CasePath $case.Path -Public

[pscustomobject]@{ Case = $case; Diff = $diff.Summary; Summaries = $summaries; HtmlReport = $report.FullName; InternalBundle = $internal.FullName; PublicBundle = $public.FullName }
