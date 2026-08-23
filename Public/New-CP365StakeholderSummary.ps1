function New-CP365StakeholderSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CasePath,
        [ValidateSet('en', 'pt-BR', 'es')][string[]]$Language = @('en', 'pt-BR', 'es')
    )

    $context = Get-CP365CaseContext -CasePath $CasePath
    $diffFile = Get-ChildItem -LiteralPath (Join-Path $context.Root 'diff') -Filter 'diff-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $diffFile) { throw 'No snapshot comparison was found. Run Compare-CP365Snapshot first.' }

    $changes = @(Get-Content -LiteralPath $diffFile.FullName -Raw | ConvertFrom-Json -Depth 100)
    $counts = [ordered]@{
        Total      = $changes.Count
        Expected   = @($changes | Where-Object classification -eq 'Expected').Count
        Unexpected = @($changes | Where-Object classification -eq 'Unexpected').Count
        Forbidden  = @($changes | Where-Object classification -eq 'Forbidden').Count
    }
    $decision = if ($counts.Forbidden -gt 0) { 'STOP' } elseif ($counts.Unexpected -gt 0) { 'REVIEW' } else { 'ALIGNED' }

    $copy = @{
        'en' = @{ Heading = 'Change evidence summary'; Target = 'Target'; Result = 'Evidence result'; Total = 'Total deltas'; Expected = 'Expected'; Unexpected = 'Unexpected'; Forbidden = 'Forbidden'; Note = 'This summary is generated from structured evidence. It does not infer business impact.' }
        'pt-BR' = @{ Heading = 'Resumo de evidências da mudança'; Target = 'Destino'; Result = 'Resultado das evidências'; Total = 'Total de diferenças'; Expected = 'Esperadas'; Unexpected = 'Inesperadas'; Forbidden = 'Proibidas'; Note = 'Este resumo é gerado a partir de evidências estruturadas. Ele não presume impacto no negócio.' }
        'es' = @{ Heading = 'Resumen de evidencias del cambio'; Target = 'Destino'; Result = 'Resultado de las evidencias'; Total = 'Diferencias totales'; Expected = 'Esperadas'; Unexpected = 'Inesperadas'; Forbidden = 'Prohibidas'; Note = 'Este resumen se genera a partir de evidencias estructuradas. No infiere impacto en el negocio.' }
    }

    $outputs = foreach ($culture in $Language) {
        $text = $copy[$culture]
        $markdown = @(
            "# $($text.Heading)",
            '',
            "- Case: $($context.Contract.caseId) — $($context.Contract.title)",
            "- $($text.Target): $($context.Contract.target.displayName) ($($context.Contract.target.fingerprint))",
            "- $($text.Result): **$decision**",
            "- $($text.Total): $($counts.Total)",
            "- $($text.Expected): $($counts.Expected)",
            "- $($text.Unexpected): $($counts.Unexpected)",
            "- $($text.Forbidden): $($counts.Forbidden)",
            '',
            "> $($text.Note)"
        ) -join [Environment]::NewLine
        $path = Join-Path $context.Root "public/summary-$culture.md"
        $markdown | Set-Content -LiteralPath $path -Encoding utf8
        [pscustomobject]@{ Language = $culture; Path = $path; Decision = $decision }
    }

    Write-CP365LedgerEvent -CasePath $context.Root -EventType 'StakeholderSummaryCreated' -Payload @{
        languages = @($Language)
        decision = $decision
        counts = $counts
        sourceHash = Get-CP365Hash -Path $diffFile.FullName
    } | Out-Null
    $outputs
}
