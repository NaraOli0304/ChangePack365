BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../ChangePack365.psd1') -Force

    function Write-RouteInventory($Path, $Rules, [bool]$Complete = $true) {
        @{ scope = 'fictional-subscription'; complete = $Complete; rules = $Rules } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path
    }
}

Describe 'Compare-CP365AlertRoute' {
    BeforeEach {
        $beforePath = Join-Path $TestDrive 'before.json'
        $afterPath = Join-Path $TestDrive 'after.json'
        $expectedPath = Join-Path $TestDrive 'expected.json'
        $old = @{ actionGroupId = 'group-old'; destination = 'old@example.invalid' }
        $new = @{ actionGroupId = 'group-new'; destination = 'new@example.invalid' }
        $first = @{ ruleId = 'expected-rule'; severity = 1; enabled = $true; routes = @($old) }
        $second = @{ ruleId = 'critical-rule'; severity = 0; enabled = $true; routes = @($old) }
        Write-RouteInventory $beforePath @($first, $second)
    }

    It 'recognizes the expected replacement and flags a separate lost Sev 0 route' {
        $first.routes = @($new)
        Write-RouteInventory $expectedPath @($first, $second)
        $second.routes = @()
        Write-RouteInventory $afterPath @($first, $second)

        $result = Compare-CP365AlertRoute $beforePath $afterPath -ExpectedPath $expectedPath
        $result.Changes.Count | Should -Be 2
        $result.Changes[0].RuleId | Should -Be 'critical-rule'
        $result.Changes[0].Classification | Should -Be 'Unexpected'
        $result.Changes[0].CriticalRouteLost | Should -BeTrue
        $result.Changes[1].Classification | Should -Be 'Expected'
        $result.Changes[1].After.routes[0].destination | Should -Be 'new@example.invalid'
    }

    It 'ignores route order and reports a planned change that did not happen' {
        $first.routes = @($old, $new)
        Write-RouteInventory $beforePath @($first, $second)
        $first.routes = @($new, $old)
        Write-RouteInventory $afterPath @($first, $second)
        (Compare-CP365AlertRoute $beforePath $afterPath).Changes.Count | Should -Be 0
        $first.routes = @($new)
        Write-RouteInventory $expectedPath @($first, $second)

        (Compare-CP365AlertRoute $beforePath $afterPath -ExpectedPath $expectedPath).Changes[0].Classification |
            Should -Be 'Unexpected'
    }

    It 'rejects incomplete inventories instead of reporting lost routes' {
        Write-RouteInventory $afterPath @() $false
        { Compare-CP365AlertRoute $beforePath $afterPath } | Should -Throw '*complete alert inventory*'
    }
}
