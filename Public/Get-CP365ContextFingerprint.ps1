function Get-CP365ContextFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Account,
        [ValidateSet('Global', 'USGov', 'China')][string]$Cloud = 'Global'
    )

    $hash = (Get-CP365Hash -Text "$($TenantId.ToLowerInvariant())|$($Account.ToLowerInvariant())|$Cloud").ToUpperInvariant()
    "CP365-$($hash.Substring(0,4))-$($hash.Substring(4,4))-$($hash.Substring(8,4))"
}
