BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../ChangePack365.psd1') -Force
}

Describe 'Intune Windows Update policy snapshots' {
    BeforeEach {
        $script:IntunePolicyId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $script:IntunePolicyUri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations/$script:IntunePolicyId"
        $script:IntuneAssignmentsUri = "$script:IntunePolicyUri/assignments"
        $script:IntuneEmptyUri = "$script:IntuneAssignmentsUri`?`$skiptoken=empty"
        $script:IntuneLastUri = "$script:IntuneAssignmentsUri`?`$skiptoken=last"
        $script:IntuneRequests = [System.Collections.Generic.List[string]]::new()
        $script:IntuneAsObject = $false
        $script:IntuneContext = [pscustomobject]@{
            TenantId = '11111111-2222-4333-8444-555555555555'
            Account = 'operator@contoso.example'
            AuthType = 'Delegated'
            Environment = 'Global'
            Scopes = @('DeviceManagementConfiguration.Read.All')
        }
        $script:IntuneResponses = @{}
        $script:IntuneResponses[$script:IntunePolicyUri] = @{
            '@odata.type' = '#microsoft.graph.windowsUpdateForBusinessConfiguration'
            id = $script:IntunePolicyId
            displayName = 'Fictional update ring'
            qualityUpdatesDeferralPeriodInDays = 0
            lastModifiedDateTime = '2026-01-01T12:00:00Z'
        }
        $script:IntuneResponses[$script:IntuneAssignmentsUri] = @{
            value = @(@{ id = 'assignment-b'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' } })
            '@odata.nextLink' = $script:IntuneEmptyUri
        }
        $script:IntuneResponses[$script:IntuneEmptyUri] = @{ value = @(); '@odata.nextLink' = $script:IntuneLastUri }
        $script:IntuneResponses[$script:IntuneLastUri] = @{
            value = @(@{ id = 'assignment-a'; target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } })
        }
        function global:Get-MgContext { return $script:IntuneContext }
        function global:Invoke-MgGraphRequest {
            param([string]$Method, [string]$Uri)
            if ($Method -ne 'GET') { throw 'Unexpected Graph write.' }
            $script:IntuneRequests.Add($Uri)
            if (-not $script:IntuneResponses.ContainsKey($Uri)) { throw "Unexpected URI: $Uri" }
            $response = $script:IntuneResponses[$Uri]
            if ($response -is [System.Exception]) { throw $response }
            if ($script:IntuneAsObject -and $response -is [System.Collections.IDictionary]) { return [pscustomobject]$response }
            return $response
        }
        $script:IntuneCase = New-CP365Case -CaseId ('INTUNE-' + [guid]::NewGuid().ToString('N')) -Title 'Fictional Intune change' -TenantId $script:IntuneContext.TenantId -TenantDisplayName Contoso -Account $script:IntuneContext.Account -Workload Intune -RootPath (Join-Path $TestDrive 'cases') -ExpectedChange @(@{ path = '$.policy.qualityUpdatesDeferralPeriodInDays'; operation = 'Modified' })
    }

    AfterEach {
        Remove-Item Function:\Get-MgContext -ErrorAction SilentlyContinue
        Remove-Item Function:\Invoke-MgGraphRequest -ErrorAction SilentlyContinue
    }

    It 'exports the snapshot command' {
        Get-Command Save-CP365IntuneUpdatePolicySnapshot -Module ChangePack365 -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    It 'collects complete sorted evidence from <Format> responses' -ForEach @(
        @{ Format = 'Hashtable'; AsObject = $false }
        @{ Format = 'PSCustomObject'; AsObject = $true }
    ) {
        $script:IntuneAsObject = $AsObject
        $result = Save-CP365IntuneUpdatePolicySnapshot -CasePath $script:IntuneCase.Path -Phase before -PolicyId $script:IntunePolicyId
        $snapshot = Get-Content -LiteralPath $result.Path -Raw | ConvertFrom-Json -Depth 100
        $result.AssignmentCount | Should -Be 2
        $result.ReadOnly | Should -BeTrue
        $result.PolicyId | Should -Be $script:IntunePolicyId
        $snapshot.policy.qualityUpdatesDeferralPeriodInDays | Should -Be 0
        ([string]$snapshot.policy.lastModifiedDateTime) | Should -Not -BeNullOrEmpty
        ($snapshot.assignments.id -join ',') | Should -Be 'assignment-a,assignment-b'
        $snapshot.assignments[1].target.groupId | Should -Be 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        $events = Get-Content (Join-Path $script:IntuneCase.Path 'ledger.jsonl') | ConvertFrom-Json
        $collected = @($events | Where-Object eventType -EQ 'GraphSnapshotCollected')
        $collected.Count | Should -Be 1
        $collected[0].payload.assignmentCount | Should -Be 2
        $collected[0].payload.resource | Should -Be 'IntuneWindowsUpdatePolicy'
        (Test-CP365Ledger -CasePath $script:IntuneCase.Path).Valid | Should -BeTrue
    }

    It 'compares before and after snapshots using the existing change contract' {
        $before = Save-CP365IntuneUpdatePolicySnapshot -CasePath $script:IntuneCase.Path -Phase before -PolicyId $script:IntunePolicyId
        $script:IntuneResponses[$script:IntunePolicyUri].qualityUpdatesDeferralPeriodInDays = 3
        $after = Save-CP365IntuneUpdatePolicySnapshot -CasePath $script:IntuneCase.Path -Phase after -PolicyId $script:IntunePolicyId
        $delta = Compare-CP365Snapshot -CasePath $script:IntuneCase.Path -BeforePath $before.Path -AfterPath $after.Path
        $delta.Summary.expected | Should -Be 1
        $delta.Summary.unexpected | Should -Be 0
        (Test-CP365Ledger -CasePath $script:IntuneCase.Path).Valid | Should -BeTrue
    }

    It 'records an empty successful assignment collection as empty' {
        $script:IntuneResponses[$script:IntuneAssignmentsUri] = @{ value = @() }
        $result = Save-CP365IntuneUpdatePolicySnapshot -CasePath $script:IntuneCase.Path -Phase before -PolicyId $script:IntunePolicyId
        $snapshot = Get-Content -LiteralPath $result.Path -Raw | ConvertFrom-Json -Depth 100
        $result.AssignmentCount | Should -Be 0
        @($snapshot.assignments).Count | Should -Be 0
    }

    It 'rejects an invalid <Field> before contacting Graph' -ForEach @(
        @{ Field = 'TenantId'; BadValue = '99999999-2222-4333-8444-555555555555'; Message = '*tenant mismatch*' }
        @{ Field = 'Account'; BadValue = 'other@contoso.example'; Message = '*account mismatch*' }
        @{ Field = 'AuthType'; BadValue = 'AppOnly'; Message = '*delegated*' }
        @{ Field = 'Environment'; BadValue = 'USGov'; Message = '*Global*' }
        @{ Field = 'Scopes'; BadValue = @(); Message = '*DeviceManagementConfiguration.Read.All*' }
    ) {
        $script:IntuneContext.$Field = $BadValue
        { Save-CP365IntuneUpdatePolicySnapshot -CasePath $script:IntuneCase.Path -Phase before -PolicyId $script:IntunePolicyId } | Should -Throw $Message
        $script:IntuneRequests.Count | Should -Be 0
        @(Get-Content (Join-Path $script:IntuneCase.Path 'ledger.jsonl')).Count | Should -Be 1
    }

    It 'rejects a <Problem> policy response' -ForEach @(
        @{ Problem = 'different type'; Property = '@odata.type'; BadValue = '#microsoft.graph.windows10GeneralConfiguration'; Message = '*windowsUpdateForBusinessConfiguration*' }
        @{ Problem = 'different ID'; Property = 'id'; BadValue = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; Message = '*policy ID mismatch*' }
        @{ Problem = 'missing type'; Property = '@odata.type'; BadValue = $null; Message = '*windowsUpdateForBusinessConfiguration*' }
    ) {
        $script:IntuneResponses[$script:IntunePolicyUri][$Property] = $BadValue
        { Save-CP365IntuneUpdatePolicySnapshot -CasePath $script:IntuneCase.Path -Phase before -PolicyId $script:IntunePolicyId } | Should -Throw $Message
        Test-Path (Join-Path $script:IntuneCase.Path "before/intune-update-policy-$script:IntunePolicyId.json") | Should -BeFalse
    }

    It 'does not save a partial snapshot when an assignment page fails' {
        $script:IntuneResponses[$script:IntuneLastUri] = [System.InvalidOperationException]::new('Synthetic HTTP 429 assignment failure.')
        { Save-CP365IntuneUpdatePolicySnapshot -CasePath $script:IntuneCase.Path -Phase before -PolicyId $script:IntunePolicyId } | Should -Throw '*Synthetic HTTP 429*'
        Test-Path (Join-Path $script:IntuneCase.Path "before/intune-update-policy-$script:IntunePolicyId.json") | Should -BeFalse
        $events = Get-Content (Join-Path $script:IntuneCase.Path 'ledger.jsonl') | ConvertFrom-Json
        @($events | Where-Object eventType -EQ 'GraphSnapshotCollected').Count | Should -Be 0
        (Test-CP365Ledger -CasePath $script:IntuneCase.Path).Valid | Should -BeTrue
    }

    It 'rejects a malformed <Problem> assignment collection' -ForEach @(
        @{ Problem = 'missing value'; Response = @{} }
        @{ Problem = 'null value'; Response = @{ value = $null } }
        @{ Problem = 'dictionary value'; Response = @{ value = @{ id = 'not-an-array' } } }
    ) {
        $script:IntuneResponses[$script:IntuneAssignmentsUri] = $Response
        { Save-CP365IntuneUpdatePolicySnapshot -CasePath $script:IntuneCase.Path -Phase before -PolicyId $script:IntunePolicyId } | Should -Throw '*assignment collection*'
        Test-Path (Join-Path $script:IntuneCase.Path "before/intune-update-policy-$script:IntunePolicyId.json") | Should -BeFalse
    }

    It 'rejects a <Problem> continuation link' -ForEach @(
        @{ Problem = 'foreign host'; Link = 'https://example.invalid/assignments'; Message = '*continuation link*' }
        @{ Problem = 'different policy'; Link = 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/assignments'; Message = '*continuation link*' }
        @{ Problem = 'cycle'; Link = $null; Message = '*pagination cycle*' }
    ) {
        $nextLink = if ($Problem -eq 'cycle') { $script:IntuneAssignmentsUri } else { $Link }
        $script:IntuneResponses[$script:IntuneAssignmentsUri]['@odata.nextLink'] = $nextLink
        { Save-CP365IntuneUpdatePolicySnapshot -CasePath $script:IntuneCase.Path -Phase before -PolicyId $script:IntunePolicyId } | Should -Throw $Message
        $script:IntuneRequests.Count | Should -Be 2
        Test-Path (Join-Path $script:IntuneCase.Path "before/intune-update-policy-$script:IntunePolicyId.json") | Should -BeFalse
    }

    It 'rejects duplicate assignment IDs instead of hiding inconsistent pages' {
        $script:IntuneResponses[$script:IntuneLastUri].value[0].id = 'assignment-b'
        { Save-CP365IntuneUpdatePolicySnapshot -CasePath $script:IntuneCase.Path -Phase before -PolicyId $script:IntunePolicyId } | Should -Throw '*duplicate assignment*'
        Test-Path (Join-Path $script:IntuneCase.Path "before/intune-update-policy-$script:IntunePolicyId.json") | Should -BeFalse
    }

    It 'rejects an empty policy ID before contacting Graph' {
        { Save-CP365IntuneUpdatePolicySnapshot -CasePath $script:IntuneCase.Path -Phase before -PolicyId ([guid]::Empty) } | Should -Throw '*PolicyId must not be empty*'
        $script:IntuneRequests.Count | Should -Be 0
    }
}
