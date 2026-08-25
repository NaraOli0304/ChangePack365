function Export-CP365Case {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$CasePath,
        [string]$OutputPath,
        [switch]$Public
    )

    $context = Get-CP365CaseContext -CasePath $CasePath
    $ledger = Test-CP365Ledger -CasePath $context.Root
    if (-not $ledger.Valid) { throw "Ledger validation failed: $($ledger.Errors -join ' ')" }
    $output = if ($OutputPath) { $OutputPath } else { Join-Path $context.Root 'artifacts' }
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $stage = Join-Path ([IO.Path]::GetTempPath()) "cp365-$([guid]::NewGuid().Guid)"
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        $salt = (Get-Content -LiteralPath (Join-Path $context.Root '.redaction-salt') -Raw).Trim()
        $excludedRoots = if ($Public) {
            @('artifacts')
        } else {
            @('artifacts', 'public')
        }
        $files = Get-ChildItem -LiteralPath $context.Root -File -Recurse | Where-Object {
            $relative = [IO.Path]::GetRelativePath($context.Root, $_.FullName)
            ($relative -ne '.redaction-salt') -and ($excludedRoots -notcontains ($relative -split '[\\/]')[0])
        }
        $manifest = foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($context.Root, $file.FullName)
            $destination = Join-Path $stage $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            if ($Public -and $file.Extension -in @('.json', '.jsonl', '.csv', '.md', '.txt', '.ps1', '.html')) {
                Protect-CP365Text -Text (Get-Content -LiteralPath $file.FullName -Raw) -Salt $salt | Set-Content -LiteralPath $destination -Encoding utf8
            } else {
                Copy-Item -LiteralPath $file.FullName -Destination $destination
            }
            [pscustomobject]@{ path = $relative.Replace('\', '/'); sha256 = Get-CP365Hash -Path $destination; bytes = (Get-Item $destination).Length }
        }
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding utf8
        $kind = if ($Public) { 'public' } else { 'internal' }
        $zip = Join-Path $output "$($context.Contract.caseId)-$kind.zip"
        if ($PSCmdlet.ShouldProcess($zip, 'Export ChangePack365 bundle')) {
            if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
            Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
            Write-CP365LedgerEvent -CasePath $context.Root -EventType 'CaseExported' -Payload @{ kind = $kind; file = Split-Path -Leaf $zip; sha256 = Get-CP365Hash -Path $zip; ledgerHead = $ledger.HeadHash } | Out-Null
            Get-Item $zip
        }
    } finally {
        if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}
