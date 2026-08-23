function Save-CP365ConditionalAccessSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CasePath,
        [Parameter(Mandatory)][ValidateSet('before', 'after')][string]$Phase,
        [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$PolicyId
    )

    $context = Get-CP365CaseContext -CasePath $CasePath
    foreach ($command in @('Get-MgContext', 'Invoke-MgGraphRequest')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Microsoft Graph PowerShell is required. Command '$command' was not found."
        }
    }

    $graphContext = Get-MgContext
    if (-not $graphContext) { throw 'No Microsoft Graph session was found. Run Connect-MgGraph first.' }
    if ([string]$graphContext.AuthType -ne 'Delegated') {
        throw 'The MVP adapter supports delegated Microsoft Graph sessions only.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$graphContext.Account)) {
        throw 'The delegated Microsoft Graph context does not expose an account.'
    }
    if ([string]$graphContext.TenantId -ne [string]$context.Contract.target.tenantId) {
        throw "Graph tenant mismatch. Contract: $($context.Contract.target.tenantId); session: $($graphContext.TenantId)."
    }

    $observedFingerprint = Get-CP365ContextFingerprint -TenantId $graphContext.TenantId -Account $graphContext.Account -Cloud $context.Contract.target.cloud
    if ($observedFingerprint -ne [string]$context.Contract.target.fingerprint) {
        throw "Graph account mismatch. Expected fingerprint $($context.Contract.target.fingerprint); observed $observedFingerprint."
    }
    $scopes = @($graphContext.Scopes)
    if (($scopes -notcontains 'Policy.Read.All') -and ($scopes -notcontains 'Policy.Read.ConditionalAccess')) {
        throw 'The Graph session is missing Policy.Read.All or Policy.Read.ConditionalAccess.'
    }

    $uri = if ($PolicyId) {
        "/v1.0/identity/conditionalAccess/policies/$PolicyId"
    } else {
        '/v1.0/identity/conditionalAccess/policies'
    }
    $policies = [System.Collections.Generic.List[object]]::new()
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
        if ($PolicyId) {
            $policies.Add($response)
            $uri = $null
        } else {
            foreach ($policy in @($response.value)) { $policies.Add($policy) }
            $nextProperty = $response.PSObject.Properties['@odata.nextLink']
            $uri = if ($nextProperty) { [string]$nextProperty.Value } else { $null }
        }
    } while ($uri)

    $snapshot = [ordered]@{
        policies = @($policies | Sort-Object { [string]$_.id })
    }
    $name = if ($PolicyId) { "conditional-access-$PolicyId.json" } else { 'conditional-access-all.json' }
    $tempFile = Join-Path ([IO.Path]::GetTempPath()) "cp365-$([guid]::NewGuid().Guid).json"
    try {
        $snapshot | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tempFile -Encoding utf8
        $evidence = Add-CP365Evidence -CasePath $context.Root -Phase $Phase -Path $tempFile -Name $name
        Write-CP365LedgerEvent -CasePath $context.Root -EventType 'GraphSnapshotCollected' -Payload @{
            phase = $Phase
            provider = 'MicrosoftGraph'
            resource = 'ConditionalAccessPolicy'
            policyId = if ($PolicyId) { $PolicyId } else { 'all' }
            count = $policies.Count
            fingerprint = $observedFingerprint
        } | Out-Null
        [pscustomobject]@{
            Phase = $Phase
            Path = $evidence.Path
            PolicyCount = $policies.Count
            Fingerprint = $observedFingerprint
            ReadOnly = $true
        }
    } finally {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
    }
}
