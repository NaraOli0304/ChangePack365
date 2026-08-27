BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'ChangePack365.psd1') -Force
}

Describe 'Invoke-CP365GraphTimeSlicedRead' {
    It 'rejects non-Microsoft Graph base URIs' {
        {
            Invoke-CP365GraphTimeSlicedRead `
                -BaseUri 'https://example.com/v1.0/items' `
                -StartUtc ([datetime]'2026-01-01T00:00:00Z') `
                -EndUtc ([datetime]'2026-01-01T01:00:00Z') `
                -DateProperty 'createdDateTime' `
                -OutputDirectory $TestDrive
        } | Should -Throw
    }

    It 'rejects invalid time windows' {
        {
            Invoke-CP365GraphTimeSlicedRead `
                -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns' `
                -StartUtc ([datetime]'2026-01-01T01:00:00Z') `
                -EndUtc ([datetime]'2026-01-01T00:00:00Z') `
                -DateProperty 'createdDateTime' `
                -OutputDirectory $TestDrive
        } | Should -Throw
    }

    It 'is GET-only and writes a complete checkpoint for a successful slice' {
        InModuleScope ChangePack365 {
            function Invoke-MgGraphRequest {
                param($Method, $Uri, $ErrorAction)
                if ($Method -ne 'GET') { throw "Unexpected method: $Method" }
                return @{
                    value = @(
                        @{ id = 'evt-1'; createdDateTime = '2026-01-01T00:01:00Z' },
                        @{ id = 'evt-2'; createdDateTime = '2026-01-01T00:02:00Z' }
                    )
                }
            }

            Mock Get-Command { @{ Name = 'Invoke-MgGraphRequest' } } -ParameterFilter { $Name -eq 'Invoke-MgGraphRequest' }

            $result = Invoke-CP365GraphTimeSlicedRead `
                -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns' `
                -StartUtc ([datetime]'2026-01-01T00:00:00Z') `
                -EndUtc ([datetime]'2026-01-01T00:15:00Z') `
                -DateProperty 'createdDateTime' `
                -OutputDirectory $TestDrive `
                -InitialWindowMinutes 15

            $result.QueryMode | Should -Be 'GET_ONLY'
            $result.Complete | Should -BeTrue
            $result.RecordCount | Should -Be 2
            Test-Path $result.ManifestPath | Should -BeTrue
        }
    }

    It 'deduplicates records by identity property when returning data' {
        InModuleScope ChangePack365 {
            function Invoke-MgGraphRequest {
                param($Method, $Uri, $ErrorAction)
                return @{
                    value = @(
                        @{ id = 'evt-1'; createdDateTime = '2026-01-01T00:01:00Z' },
                        @{ id = 'evt-1'; createdDateTime = '2026-01-01T00:01:00Z' }
                    )
                }
            }

            Mock Get-Command { @{ Name = 'Invoke-MgGraphRequest' } } -ParameterFilter { $Name -eq 'Invoke-MgGraphRequest' }

            $result = Invoke-CP365GraphTimeSlicedRead `
                -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns' `
                -StartUtc ([datetime]'2026-01-01T00:00:00Z') `
                -EndUtc ([datetime]'2026-01-01T00:15:00Z') `
                -DateProperty 'createdDateTime' `
                -OutputDirectory $TestDrive `
                -InitialWindowMinutes 15 `
                -PassThru

            @($result.Records).Count | Should -Be 1
        }
    }
}
