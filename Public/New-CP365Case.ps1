function New-CP365Case {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$CaseId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TenantId,
        [Parameter(Mandatory)][string]$TenantDisplayName,
        [Parameter(Mandatory)][string]$Account,
        [string[]]$Workload = @('MicrosoftGraph'),
        [object[]]$ExpectedChange = @(),
        [object[]]$ForbiddenChange = @(),
        [ValidateSet('ReadOnly', 'ControlledWrite')][string]$Mode = 'ReadOnly',
        [string]$RootPath = (Join-Path $PWD '.change-pack')
    )

    $casePath = Join-Path $RootPath $CaseId
    if (Test-Path -LiteralPath $casePath) { throw "Case '$CaseId' already exists." }
    if (-not $PSCmdlet.ShouldProcess($casePath, 'Create ChangePack365 case')) { return }

    foreach ($folder in @('before', 'after', 'diff', 'logs', 'rollback', 'public', 'artifacts')) {
        New-Item -ItemType Directory -Path (Join-Path $casePath $folder) -Force | Out-Null
    }

    $fingerprint = Get-CP365ContextFingerprint -TenantId $TenantId -Account $Account
    $contract = [ordered]@{
        schemaVersion    = '1.0'
        caseId           = $CaseId
        title            = $Title
        createdUtc       = [DateTime]::UtcNow.ToString('o')
        mode             = $Mode
        target           = [ordered]@{
            tenantId       = $TenantId.ToLowerInvariant()
            displayName    = $TenantDisplayName
            account        = $Account
            cloud          = 'Global'
            fingerprint    = $fingerprint
            workloads      = @($Workload)
        }
        expectedChanges  = @($ExpectedChange)
        forbiddenChanges = @($ForbiddenChange)
        approvals        = @()
        privacy          = [ordered]@{
            publicBundle = $true
            maskTypes    = @('UPN', 'GUID', 'IPv4')
        }
    }
    $contract | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $casePath 'contract.json') -Encoding utf8
    [guid]::NewGuid().Guid | Set-Content -LiteralPath (Join-Path $casePath '.redaction-salt') -Encoding utf8
    Write-CP365LedgerEvent -CasePath $casePath -EventType 'CaseCreated' -Payload @{ contractHash = Get-CP365Hash -File (Join-Path $casePath 'contract.json'); fingerprint = $fingerprint } | Out-Null

    [pscustomobject]@{ CaseId = $CaseId; Path = $casePath; Fingerprint = $fingerprint; Mode = $Mode }
}
