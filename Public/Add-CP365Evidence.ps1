function Add-CP365Evidence {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$CasePath,
        [Parameter(Mandatory)][ValidateSet('before', 'after', 'logs', 'rollback', 'artifacts')][string]$Phase,
        [Parameter(Mandatory)][string]$Path,
        [string]$Name
    )

    $context = Get-CP365CaseContext -CasePath $CasePath
    $source = (Resolve-Path -LiteralPath $Path).Path
    $fileName = if ($Name) { $Name } else { Split-Path -Leaf $source }
    $destination = Join-Path (Join-Path $context.Root $Phase) $fileName
    if (-not $PSCmdlet.ShouldProcess($destination, 'Add evidence')) { return }
    Copy-Item -LiteralPath $source -Destination $destination -Force
    $hash = Get-CP365Hash -File $destination
    Write-CP365LedgerEvent -CasePath $context.Root -EventType 'EvidenceAdded' -Payload @{ phase = $Phase; file = "$Phase/$fileName"; sha256 = $hash } | Out-Null
    [pscustomobject]@{ Phase = $Phase; Path = $destination; Sha256 = $hash }
}
