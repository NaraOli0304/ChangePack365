function Save-CP365IntuneUpdatePolicySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CasePath,
        [Parameter(Mandatory)][ValidateSet('before', 'after')][string]$Phase,
        [Parameter(Mandatory)][guid]$PolicyId
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    if ($PolicyId -eq [guid]::Empty) { throw 'PolicyId must not be empty.' }
    $id = $PolicyId.ToString('D')
    $context = Get-CP365CaseContext -CasePath $CasePath
    foreach ($command in @('Get-MgContext', 'Invoke-MgGraphRequest')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Microsoft Graph PowerShell is required. Command '$command' was not found."
        }
    }

    $graphContext = Get-MgContext
    if (-not $graphContext) { throw 'No Microsoft Graph session was found. Run Connect-MgGraph first.' }
    if ([string]$graphContext.AuthType -ne 'Delegated') {
        throw 'The Intune adapter supports delegated Microsoft Graph sessions only.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$graphContext.Account)) {
        throw 'The delegated Microsoft Graph context does not expose an account.'
    }
    if ([string]$context.Contract.target.cloud -ne 'Global' -or [string]$graphContext.Environment -ne 'Global') {
        throw 'The Intune adapter supports the Global Graph environment only.'
    }
    if ([string]$graphContext.TenantId -ne [string]$context.Contract.target.tenantId) {
        throw 'Graph tenant mismatch with the case contract.'
    }
    $fingerprint = Get-CP365ContextFingerprint -TenantId $graphContext.TenantId -Account $graphContext.Account -Cloud $graphContext.Environment
    if ($fingerprint -ne [string]$context.Contract.target.fingerprint) {
        throw 'Graph account mismatch with the case contract.'
    }
    if (@($graphContext.Scopes) -notcontains 'DeviceManagementConfiguration.Read.All') {
        throw 'The Graph session is missing DeviceManagementConfiguration.Read.All.'
    }

    $policyUri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations/$id"
    $policy = Invoke-MgGraphRequest -Method GET -Uri $policyUri -ErrorAction Stop
    if ($policy -is [System.Collections.IDictionary]) { $policy = [pscustomobject]$policy }
    if ($null -eq $policy) { throw 'Expected a windowsUpdateForBusinessConfiguration policy response.' }
    $typeProperty = $policy.PSObject.Properties['@odata.type']
    if ($null -eq $typeProperty -or [string]$typeProperty.Value -ne '#microsoft.graph.windowsUpdateForBusinessConfiguration') {
        throw 'Expected a windowsUpdateForBusinessConfiguration policy response.'
    }
    $idProperty = $policy.PSObject.Properties['id']
    if ($null -eq $idProperty -or [string]$idProperty.Value -ne $id) {
        throw 'Graph policy ID mismatch with the requested PolicyId.'
    }

    $assignmentsPath = "/v1.0/deviceManagement/deviceConfigurations/$id/assignments"
    $uri = [uri]("https://graph.microsoft.com" + $assignmentsPath)
    $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $assignmentIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $assignments = [System.Collections.Generic.List[object]]::new()
    do {
        if (-not $visited.Add($uri.AbsoluteUri)) { throw 'Intune assignment pagination cycle detected.' }
        $page = Invoke-MgGraphRequest -Method GET -Uri $uri.AbsoluteUri -ErrorAction Stop
        if ($page -is [System.Collections.IDictionary]) { $page = [pscustomobject]$page }
        if ($null -eq $page) { throw 'Invalid Intune assignment collection response.' }
        $valueProperty = $page.PSObject.Properties['value']
        if ($null -eq $valueProperty -or $null -eq $valueProperty.Value -or
            $valueProperty.Value -is [string] -or $valueProperty.Value -is [System.Collections.IDictionary] -or
            $valueProperty.Value -isnot [System.Collections.IEnumerable]) {
            throw 'Invalid Intune assignment collection response.'
        }
        foreach ($assignment in $valueProperty.Value) {
            if ($assignment -is [System.Collections.IDictionary]) { $assignment = [pscustomobject]$assignment }
            if ($null -eq $assignment) { throw 'Invalid Intune assignment record.' }
            $assignmentId = $assignment.PSObject.Properties['id']
            if ($null -eq $assignmentId -or [string]::IsNullOrWhiteSpace([string]$assignmentId.Value)) {
                throw 'Invalid Intune assignment record: missing ID.'
            }
            if (-not $assignmentIds.Add([string]$assignmentId.Value)) { throw 'Duplicate assignment ID in Intune response.' }
            $assignments.Add($assignment)
        }

        $nextProperty = $page.PSObject.Properties['@odata.nextLink']
        $uri = $null
        if ($null -ne $nextProperty -and -not [string]::IsNullOrWhiteSpace([string]$nextProperty.Value)) {
            [uri]$nextUri = $null
            if (-not [uri]::TryCreate([string]$nextProperty.Value, [UriKind]::Absolute, [ref]$nextUri) -or
                $nextUri.Scheme -ne 'https' -or $nextUri.Host -ne 'graph.microsoft.com' -or
                $nextUri.Port -ne 443 -or $nextUri.UserInfo -or $nextUri.Fragment -or
                $nextUri.AbsolutePath.TrimEnd('/') -ne $assignmentsPath) {
                throw 'Invalid Intune assignment continuation link: expected the same policy on Global Graph v1.0.'
            }
            $uri = $nextUri
        }
    } while ($uri)

    $snapshot = [ordered]@{
        policy = $policy
        assignments = @($assignments | Sort-Object { [string]$_.id })
    }
    $tempFile = Join-Path ([IO.Path]::GetTempPath()) "cp365-intune-$([guid]::NewGuid().ToString('N')).json"
    try {
        $snapshot | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tempFile -Encoding utf8
        $evidence = Add-CP365Evidence -CasePath $context.Root -Phase $Phase -Path $tempFile -Name "intune-update-policy-$id.json"
        Write-CP365LedgerEvent -CasePath $context.Root -EventType 'GraphSnapshotCollected' -Payload @{
            phase = $Phase
            provider = 'MicrosoftGraph'
            resource = 'IntuneWindowsUpdatePolicy'
            policyId = $id
            assignmentCount = $assignments.Count
            fingerprint = $fingerprint
        } | Out-Null
        [pscustomobject]@{
            Phase = $Phase
            Path = $evidence.Path
            PolicyId = $id
            AssignmentCount = $assignments.Count
            Fingerprint = $fingerprint
            ReadOnly = $true
        }
    } finally {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
    }
}
