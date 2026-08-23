function Confirm-CP365WriteContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CasePath,
        [Parameter(Mandatory)][string]$ObservedTenantId,
        [Parameter(Mandatory)][string]$ObservedAccount,
        [switch]$NonInteractive,
        [string]$Confirmation
    )

    $context = Get-CP365CaseContext -CasePath $CasePath
    if ($context.Contract.mode -ne 'ControlledWrite') { throw 'The contract is not in ControlledWrite mode.' }
    $observed = Get-CP365ContextFingerprint -TenantId $ObservedTenantId -Account $ObservedAccount -Cloud $context.Contract.target.cloud
    $expected = [string]$context.Contract.target.fingerprint
    if ($observed -ne $expected) {
        Write-CP365LedgerEvent -CasePath $CasePath -EventType 'ContextRejected' -Payload @{ expected = $expected; observed = $observed } | Out-Null
        throw "Tenant context mismatch. Expected $expected but observed $observed."
    }

    $phrase = "APPLY $expected"
    $provided = if ($NonInteractive) { $Confirmation } else { Read-Host "Type '$phrase' to unlock this change session" }
    if ($provided -cne $phrase) {
        Write-CP365LedgerEvent -CasePath $CasePath -EventType 'ConfirmationRejected' -Payload @{ fingerprint = $expected } | Out-Null
        throw 'Exact confirmation phrase was not provided.'
    }

    Write-CP365LedgerEvent -CasePath $CasePath -EventType 'WriteContextConfirmed' -Payload @{ fingerprint = $expected } | Out-Null
    $true
}
