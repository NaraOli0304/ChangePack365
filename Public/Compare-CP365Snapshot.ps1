function Compare-CP365Snapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CasePath,
        [Parameter(Mandatory)][string]$BeforePath,
        [Parameter(Mandatory)][string]$AfterPath
    )

    $context = Get-CP365CaseContext -CasePath $CasePath
    $before = Get-Content -LiteralPath $BeforePath -Raw | ConvertFrom-Json -Depth 100
    $after = Get-Content -LiteralPath $AfterPath -Raw | ConvertFrom-Json -Depth 100
    $beforeMap = ConvertTo-CP365FlatMap $before
    $afterMap = ConvertTo-CP365FlatMap $after
    $paths = @(@($beforeMap.Keys) + @($afterMap.Keys) | Sort-Object -Unique)
    $expectedRules = @($context.Contract.expectedChanges)
    $forbiddenRules = @($context.Contract.forbiddenChanges)

    $changes = foreach ($path in $paths) {
        $hasBefore = $beforeMap.ContainsKey($path)
        $hasAfter = $afterMap.ContainsKey($path)
        if ($hasBefore -and $hasAfter -and $beforeMap[$path] -eq $afterMap[$path]) { continue }
        $operation = if (-not $hasBefore) { 'Added' } elseif (-not $hasAfter) { 'Removed' } else { 'Modified' }
        $forbiddenMatch = @($forbiddenRules | Where-Object {
            $operationProperty = $_.PSObject.Properties['operation']
            ($path -like $_.path) -and (($null -eq $operationProperty) -or [string]::IsNullOrWhiteSpace([string]$operationProperty.Value) -or ($operationProperty.Value -eq $operation))
        }).Count -gt 0
        $expectedMatch = @($expectedRules | Where-Object {
            $operationProperty = $_.PSObject.Properties['operation']
            ($path -like $_.path) -and (($null -eq $operationProperty) -or [string]::IsNullOrWhiteSpace([string]$operationProperty.Value) -or ($operationProperty.Value -eq $operation))
        }).Count -gt 0
        $classification = if ($forbiddenMatch) {
            'Forbidden'
        } elseif ($expectedMatch) {
            'Expected'
        } else { 'Unexpected' }
        [pscustomobject]@{
            path           = $path
            operation      = $operation
            classification = $classification
            before         = if ($hasBefore) { $beforeMap[$path] } else { $null }
            after          = if ($hasAfter) { $afterMap[$path] } else { $null }
        }
    }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $jsonPath = Join-Path $context.Root "diff/diff-$stamp.json"
    $csvPath = Join-Path $context.Root "diff/diff-$stamp.csv"
    @($changes) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    @($changes) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    $summary = [ordered]@{
        total      = @($changes).Count
        expected   = @($changes | Where-Object classification -eq 'Expected').Count
        unexpected = @($changes | Where-Object classification -eq 'Unexpected').Count
        forbidden  = @($changes | Where-Object classification -eq 'Forbidden').Count
        diffHash   = Get-CP365Hash -File $jsonPath
    }
    Write-CP365LedgerEvent -CasePath $context.Root -EventType 'SnapshotsCompared' -Payload $summary | Out-Null
    [pscustomobject]@{ Summary = [pscustomobject]$summary; Changes = @($changes); JsonPath = $jsonPath; CsvPath = $csvPath }
}
