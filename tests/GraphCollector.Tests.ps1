BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'ChangePack365.psd1') -Force
}

Describe 'Invoke-CP365GraphTimeSlicedRead' {
    It 'is exported by the module manifest' {
        $command = Get-Command `
            -Name 'Invoke-CP365GraphTimeSlicedRead' `
            -Module 'ChangePack365' `
            -ErrorAction Stop

        $command.Name | Should -Be 'Invoke-CP365GraphTimeSlicedRead'
        $command.CommandType | Should -Be 'Function'
    }

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

    It 'rejects a pagination nextLink outside Microsoft Graph before another request' {
        InModuleScope ChangePack365 {
            $script:externalNextLinkCalls = 0
            function Invoke-MgGraphRequest {
                param($Method, $Uri, $ErrorAction)
                $script:externalNextLinkCalls++
                return @{
                    value = @(
                        @{ id = 'evt-1'; createdDateTime = '2026-01-01T00:01:00Z' }
                    )
                    '@odata.nextLink' = 'https://example.com/v1.0/auditLogs/signIns?page=2'
                }
            }

            Mock Get-Command { @{ Name = 'Invoke-MgGraphRequest' } } -ParameterFilter { $Name -eq 'Invoke-MgGraphRequest' }

            {
                Invoke-CP365GraphTimeSlicedRead `
                    -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns' `
                    -StartUtc ([datetime]'2026-01-01T00:00:00Z') `
                    -EndUtc ([datetime]'2026-01-01T00:15:00Z') `
                    -DateProperty 'createdDateTime' `
                    -OutputDirectory (Join-Path $TestDrive 'external-next-link') `
                    -InitialWindowMinutes 15
            } | Should -Throw -ExpectedMessage '*pagination nextLink must use https://graph.microsoft.com/*'

            $script:externalNextLinkCalls | Should -Be 1
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

    It 'retries a throttled request and completes after a later success' {
        InModuleScope ChangePack365 {
            $script:retryGraphCalls = 0
            function Invoke-MgGraphRequest {
                param($Method, $Uri, $ErrorAction)
                $script:retryGraphCalls++
                if ($script:retryGraphCalls -eq 1) {
                    throw 'HTTP/1.1 429 Too Many Requests.'
                }
                return @{
                    value = @(
                        @{ id = 'evt-after-retry'; createdDateTime = '2026-01-01T00:01:00Z' }
                    )
                }
            }

            Mock Get-Command { @{ Name = 'Invoke-MgGraphRequest' } } -ParameterFilter { $Name -eq 'Invoke-MgGraphRequest' }
            Mock Start-Sleep {}

            $result = Invoke-CP365GraphTimeSlicedRead `
                -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns' `
                -StartUtc ([datetime]'2026-01-01T00:00:00Z') `
                -EndUtc ([datetime]'2026-01-01T00:15:00Z') `
                -DateProperty 'createdDateTime' `
                -OutputDirectory (Join-Path $TestDrive 'retry-success') `
                -InitialWindowMinutes 15 `
                -MaxTransientAttempts 3

            $result.Complete | Should -BeTrue
            $result.RecordCount | Should -Be 1
            $script:retryGraphCalls | Should -Be 2
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }
    }

    It 'stops retrying a throttled request at the configured attempt limit' {
        InModuleScope ChangePack365 {
            $script:limitedRetryCalls = 0
            function Invoke-MgGraphRequest {
                param($Method, $Uri, $ErrorAction)
                $script:limitedRetryCalls++
                throw 'HTTP/1.1 429 Too Many Requests.'
            }

            Mock Get-Command { @{ Name = 'Invoke-MgGraphRequest' } } -ParameterFilter { $Name -eq 'Invoke-MgGraphRequest' }
            Mock Start-Sleep {}
            $output = Join-Path $TestDrive 'retry-limit'

            {
                Invoke-CP365GraphTimeSlicedRead `
                    -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns' `
                    -StartUtc ([datetime]'2026-01-01T00:00:00Z') `
                    -EndUtc ([datetime]'2026-01-01T00:15:00Z') `
                    -DateProperty 'createdDateTime' `
                    -OutputDirectory $output `
                    -InitialWindowMinutes 15 `
                    -MaxTransientAttempts 3
            } | Should -Throw

            $script:limitedRetryCalls | Should -Be 3
            Should -Invoke Start-Sleep -Times 2 -Exactly
            $failure = Get-ChildItem $output -Filter 'slice_*.meta.json' |
                Select-Object -First 1 |
                Get-Content -Raw |
                ConvertFrom-Json
            $failure.complete | Should -BeFalse
            $failure.httpStatus | Should -Be 429
            $failure.requestCount | Should -Be 3
        }
    }

    It 'retries each documented transient Graph server error' {
        InModuleScope ChangePack365 {
            Mock Get-Command { @{ Name = 'Invoke-MgGraphRequest' } } -ParameterFilter { $Name -eq 'Invoke-MgGraphRequest' }
            Mock Start-Sleep {}

            foreach ($status in @(500, 502, 503, 504)) {
                $script:transientStatus = $status
                $script:serverRetryCalls = 0

                function Invoke-MgGraphRequest {
                    param($Method, $Uri, $ErrorAction)
                    $script:serverRetryCalls++
                    if ($script:serverRetryCalls -eq 1) {
                        throw "HTTP/1.1 $script:transientStatus Transient Server Error."
                    }
                    return @{
                        value = @(
                            @{
                                id = "evt-after-$script:transientStatus"
                                createdDateTime = '2026-01-01T00:01:00Z'
                            }
                        )
                    }
                }

                $result = Invoke-CP365GraphTimeSlicedRead `
                    -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns' `
                    -StartUtc ([datetime]'2026-01-01T00:00:00Z') `
                    -EndUtc ([datetime]'2026-01-01T00:15:00Z') `
                    -DateProperty 'createdDateTime' `
                    -OutputDirectory (Join-Path $TestDrive "retry-$status") `
                    -InitialWindowMinutes 15 `
                    -MaxTransientAttempts 3

                $result.Complete | Should -BeTrue
                $result.RecordCount | Should -Be 1
                $script:serverRetryCalls | Should -Be 2
            }

            Should -Invoke Start-Sleep -Times 4 -Exactly
        }
    }

    It 'does not retry a permanent Graph error' {
        InModuleScope ChangePack365 {
            $script:permanentErrorCalls = 0
            function Invoke-MgGraphRequest {
                param($Method, $Uri, $ErrorAction)
                $script:permanentErrorCalls++
                throw 'HTTP/1.1 403 Forbidden.'
            }

            Mock Get-Command { @{ Name = 'Invoke-MgGraphRequest' } } -ParameterFilter { $Name -eq 'Invoke-MgGraphRequest' }
            Mock Start-Sleep {}

            {
                Invoke-CP365GraphTimeSlicedRead `
                    -BaseUri 'https://graph.microsoft.com/v1.0/auditLogs/signIns' `
                    -StartUtc ([datetime]'2026-01-01T00:00:00Z') `
                    -EndUtc ([datetime]'2026-01-01T00:15:00Z') `
                    -DateProperty 'createdDateTime' `
                    -OutputDirectory (Join-Path $TestDrive 'permanent-error') `
                    -InitialWindowMinutes 15 `
                    -MaxTransientAttempts 4
            } | Should -Throw

            $script:permanentErrorCalls | Should -Be 1
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    It 'keeps checkpoints separate when the query fingerprint changes' {
        InModuleScope ChangePack365 {
            $script:fingerprintGraphCalls = 0
            function Invoke-MgGraphRequest {
                param($Method, $Uri, $ErrorAction)
                $script:fingerprintGraphCalls++
                return @{
                    value = @(
                        @{
                            id = "evt-$script:fingerprintGraphCalls"
                            createdDateTime = '2026-01-01T00:01:00Z'
                        }
                    )
                }
            }

            Mock Get-Command { @{ Name = 'Invoke-MgGraphRequest' } } -ParameterFilter { $Name -eq 'Invoke-MgGraphRequest' }
            $output = Join-Path $TestDrive 'fingerprint-separation'
            $common = @{
                BaseUri = 'https://graph.microsoft.com/v1.0/auditLogs/signIns'
                StartUtc = [datetime]'2026-01-01T00:00:00Z'
                EndUtc = [datetime]'2026-01-01T00:15:00Z'
                DateProperty = 'createdDateTime'
                OutputDirectory = $output
                InitialWindowMinutes = 15
            }

            $first = Invoke-CP365GraphTimeSlicedRead @common -Select 'id'
            $second = Invoke-CP365GraphTimeSlicedRead @common -Select 'id,createdDateTime'

            $first.Complete | Should -BeTrue
            $second.Complete | Should -BeTrue
            $first.QueryFingerprint | Should -Not -Be $second.QueryFingerprint
            $script:fingerprintGraphCalls | Should -Be 2
            @(Get-ChildItem $output -Filter 'slice_*.jsonl').Count | Should -Be 2
            @(Get-ChildItem $output -Filter 'collection-manifest_*.json').Count | Should -Be 2
        }
    }

}
