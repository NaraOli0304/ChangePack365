function Test-CP365Ledger {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CasePath)

    $context = Get-CP365CaseContext -CasePath $CasePath
    $entries = @(Get-Content -LiteralPath $context.LedgerPath | Where-Object { $_ } | ConvertFrom-Json -Depth 100)
    $previous = 'GENESIS'
    $errors = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $entry = $entries[$index]
        $payloadHash = Get-CP365Hash -Text (ConvertTo-CP365CanonicalJson $entry.payload)
        if ($entry.payloadHash -ne $payloadHash) { $errors.Add("Entry $($index + 1): payload hash mismatch.") }
        if ($entry.previousHash -ne $previous) { $errors.Add("Entry $($index + 1): chain link mismatch.") }
        $body = [ordered]@{
            sequence = $entry.sequence; timestampUtc = $entry.timestampUtc; eventType = $entry.eventType
            actor = $entry.actor; payload = $entry.payload; payloadHash = $entry.payloadHash; previousHash = $entry.previousHash
        }
        $entryHash = Get-CP365Hash -Text (ConvertTo-CP365CanonicalJson $body)
        if ($entry.entryHash -ne $entryHash) { $errors.Add("Entry $($index + 1): entry hash mismatch.") }
        $previous = [string]$entry.entryHash
    }
    [pscustomobject]@{ Valid = ($errors.Count -eq 0); Entries = $entries.Count; HeadHash = $previous; Errors = @($errors) }
}
