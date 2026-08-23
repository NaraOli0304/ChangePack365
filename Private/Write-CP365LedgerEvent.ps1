function Write-CP365LedgerEvent {
    param(
        [Parameter(Mandatory)][string]$CasePath,
        [Parameter(Mandatory)][string]$EventType,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Payload,
        [string]$Actor = [Environment]::UserName
    )

    $context = Get-CP365CaseContext -CasePath $CasePath
    $entries = @(
        if (Test-Path -LiteralPath $context.LedgerPath) {
            Get-Content -LiteralPath $context.LedgerPath | Where-Object { $_ } | ConvertFrom-Json
        }
    )

    $previousHash = if ($entries.Count) { [string]$entries[-1].entryHash } else { 'GENESIS' }
    $payloadHash = Get-CP365Hash -Text (ConvertTo-CP365CanonicalJson $Payload)
    $body = [ordered]@{
        sequence     = $entries.Count + 1
        # Basic ISO 8601 stays a string across ConvertTo/From-Json on every supported PowerShell version.
        timestampUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmss.fffffffZ')
        eventType    = $EventType
        actor        = $Actor
        payload      = $Payload
        payloadHash  = $payloadHash
        previousHash = $previousHash
    }
    $entryHash = Get-CP365Hash -Text (ConvertTo-CP365CanonicalJson $body)
    $entry = [ordered]@{}
    foreach ($key in $body.Keys) { $entry[$key] = $body[$key] }
    $entry.entryHash = $entryHash
    Add-Content -LiteralPath $context.LedgerPath -Value ($entry | ConvertTo-Json -Depth 100 -Compress) -Encoding utf8
    [pscustomobject]$entry
}
