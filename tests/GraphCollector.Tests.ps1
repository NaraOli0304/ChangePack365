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
                -OutputDirectory (Join-Path $TestDrive 'invalid-host')
        } | Should -Throw
    }

    It 'rejects a BaseUri that already contains a query string' {
        {
            Invoke-CP365GraphTimeSlicedRead `
                -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns?$top=1' `
                -StartUtc ([datetime]'2026-01-01T00:00:00Z') `
                -EndUtc ([datetime]'2026-01-01T01:00:00Z') `
                -DateProperty 'createdDateTime' `
                -OutputDirectory (Join-Path $TestDrive 'invalid-query')
        } | Should -Throw
    }

    It 'rejects invalid time windows' {
        {
            Invoke-CP365GraphTimeSlicedRead `
                -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns' `
                -StartUtc ([datetime]'2026-01-01T01:00:00Z') `
                -EndUtc ([datetime]'2026-01-01T00:00:00Z') `
                -DateProperty 'createdDateTime' `
                -OutputDirectory (Join-Path $TestDrive 'invalid-window')
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
            $output = Join-Path $TestDrive 'success'

            $result = Invoke-CP365GraphTimeSlicedRead `
                -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns' `
                -StartUtc ([datetime]'2026-01-01T00:00:00Z') `
                -EndUtc ([datetime]'2026-01-01T00:15:00Z') `
                -DateProperty 'createdDateTime' `
                -OutputDirectory $output `
                -InitialWindowMinutes 15

            $result.QueryMode | Should -Be 'GET_ONLY'
            $result.Complete | Should -BeTrue
            $result.RecordCount | Should -Be 2
            Test-Path $result.ManifestPath | Should -BeTrue
            @(Get-ChildItem $output -Filter 'slice_*.jsonl').Count | Should -Be 1
        }
    }

    It 'deduplicates dictionary records by identity property when returning data' {
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
                -OutputDirectory (Join-Path $TestDrive 'dedup') `
                -InitialWindowMinutes 15 `
                -PassThru

            @($result.Records).Count | Should -Be 1
        }
    }

    It 'checkpoints an empty successful slice and resumes without calling Graph again' {
        InModuleScope ChangePack365 {
            $script:resumeGraphCalls = 0
            function Invoke-MgGraphRequest {
                param($Method, $Uri, $ErrorAction)
                $script:resumeGraphCalls++
                return @{ value = @() }
            }

            Mock Get-Command { @{ Name = 'Invoke-MgGraphRequest' } } -ParameterFilter { $Name -eq 'Invoke-MgGraphRequest' }
            $output = Join-Path $TestDrive 'empty-resume'
            $params = @{
                BaseUri = 'https://graph.microsoft.com/v1.0/auditLogs/signIns'
                StartUtc = [datetime]'2026-01-01T00:00:00Z'
                EndUtc = [datetime]'2026-01-01T00:15:00Z'
                DateProperty = 'createdDateTime'
                OutputDirectory = $output
                InitialWindowMinutes = 15
            }

            $first = Invoke-CP365GraphTimeSlicedRead @params
            $first.Complete | Should -BeTrue
            $first.RecordCount | Should -Be 0
            $script:resumeGraphCalls | Should -Be 1

            $second = Invoke-CP365GraphTimeSlicedRead @params
            $second.Complete | Should -BeTrue
            $second.RecordCount | Should -Be 0
            $script:resumeGraphCalls | Should -Be 1
        }
    }

    It 'subdivides a slice after a 410 and completes the child slices' {
        InModuleScope ChangePack365 {
            $script:subdivideGraphCalls = 0
            function Invoke-MgGraphRequest {
                param($Method, $Uri, $ErrorAction)
                $script:subdivideGraphCalls++
                if ($script:subdivideGraphCalls -eq 1) {
                    throw 'HTTP/1.1 410 Gone - Skip token has expired.'
                }
                return @{
                    value = @(
                        @{ id = "evt-$script:subdivideGraphCalls"; createdDateTime = '2026-01-01T00:01:00Z' }
                    )
                }
            }

            Mock Get-Command { @{ Name = 'Invoke-MgGraphRequest' } } -ParameterFilter { $Name -eq 'Invoke-MgGraphRequest' }

            $result = Invoke-CP365GraphTimeSlicedRead `
                -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns' `
                -StartUtc ([datetime]'2026-01-01T00:00:00Z') `
                -EndUtc ([datetime]'2026-01-01T00:20:00Z') `
                -DateProperty 'createdDateTime' `
                -OutputDirectory (Join-Path $TestDrive 'subdivide') `
                -InitialWindowMinutes 20 `
                -MinimumWindowMinutes 5 `
                -PassThru

            $result.Manifest.complete | Should -BeTrue
            $result.Manifest.sliceCount | Should -Be 2
            @($result.Records).Count | Should -Be 2
            $script:subdivideGraphCalls | Should -Be 3
        }
    }
}
