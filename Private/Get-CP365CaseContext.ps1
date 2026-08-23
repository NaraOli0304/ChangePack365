function Get-CP365CaseContext {
    param([Parameter(Mandatory)][string]$CasePath)

    $resolved = (Resolve-Path -LiteralPath $CasePath).Path
    $contractPath = Join-Path $resolved 'contract.json'
    if (-not (Test-Path -LiteralPath $contractPath)) {
        throw "contract.json was not found in '$resolved'."
    }

    [pscustomobject]@{
        Root         = $resolved
        ContractPath = $contractPath
        Contract     = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json -Depth 100
        LedgerPath   = Join-Path $resolved 'ledger.jsonl'
    }
}
