function Compare-CP365AlertRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BeforePath,
        [Parameter(Mandatory)][string]$AfterPath,
        [string]$ExpectedPath
    )

    $inventories = foreach ($path in @($BeforePath, $AfterPath, $ExpectedPath)) {
        if (-not $path) { continue }
        $snapshot = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        if ($snapshot -isnot [System.Collections.IDictionary] -or
            $snapshot.complete -isnot [bool] -or -not $snapshot.complete -or
            $snapshot.scope -isnot [string] -or [string]::IsNullOrWhiteSpace($snapshot.scope) -or
            $snapshot.rules -isnot [array]) {
            throw "Expected a complete alert inventory with a scope and rules array: $path"
        }

        $rules = @{}
        foreach ($rule in $snapshot.rules) {
            if ($rule -isnot [System.Collections.IDictionary] -or
                $rule.ruleId -isnot [string] -or [string]::IsNullOrWhiteSpace($rule.ruleId) -or
                $rule.enabled -isnot [bool] -or -not $rule.Contains('severity') -or
                ($null -ne $rule.severity -and ($rule.severity -isnot [long] -or $rule.severity -notin (0..4))) -or
                $rule.routes -isnot [array] -or $rules.ContainsKey($rule.ruleId)) {
                throw "Invalid or duplicate alert rule in inventory: $path"
            }
            $routes = @{}
            foreach ($route in $rule.routes) {
                if ($route -isnot [System.Collections.IDictionary] -or
                    $route.actionGroupId -isnot [string] -or [string]::IsNullOrWhiteSpace($route.actionGroupId) -or
                    $route.destination -isnot [string] -or [string]::IsNullOrWhiteSpace($route.destination)) {
                    throw "Invalid route in inventory: $path"
                }
                $groupId = $route.actionGroupId.Trim().ToLowerInvariant()
                $destination = $route.destination.Trim()
                $key = $groupId + [char]0 + $destination
                if ($routes.ContainsKey($key)) { throw "Duplicate route in inventory: $path" }
                $routes[$key] = [ordered]@{ actionGroupId = $groupId; destination = $destination }
            }
            $rules[$rule.ruleId] = [ordered]@{
                enabled = $rule.enabled
                severity = $rule.severity
                routes = @($routes.Keys | Sort-Object | ForEach-Object { $routes[$_] })
            }
        }
        [pscustomobject]@{ Scope = $snapshot.scope; Rules = $rules }
    }

    $before = $inventories[0]
    $after = $inventories[1]
    $expected = if ($ExpectedPath) { $inventories[2] } else { $before }
    if ($before.Scope -cne $after.Scope -or $before.Scope -cne $expected.Scope) {
        throw 'Alert inventories must have the same scope.'
    }

    $ids = @(@($before.Rules.Keys) + @($after.Rules.Keys) + @($expected.Rules.Keys) |
        ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    $changes = foreach ($id in $ids) {
        $prior = $before.Rules[$id]
        $actual = $after.Rules[$id]
        $target = $expected.Rules[$id]
        $priorJson = ConvertTo-Json -InputObject $prior -Depth 5 -Compress
        $actualJson = ConvertTo-Json -InputObject $actual -Depth 5 -Compress
        $targetJson = ConvertTo-Json -InputObject $target -Depth 5 -Compress
        if ($priorJson -ceq $actualJson -and $actualJson -ceq $targetJson) { continue }

        $criticalBefore = $null -ne $prior -and $prior.enabled -and
            $null -ne $prior.severity -and $prior.severity -le 1 -and $prior.routes.Count -gt 0
        $criticalRouteLost = $criticalBefore -and
            ($null -eq $actual -or -not $actual.enabled -or $actual.routes.Count -eq 0)
        $classification = if ($actualJson -cne $targetJson) { 'Unexpected' } else { 'Expected' }
        [pscustomobject]@{
            RuleId = $id
            Classification = $classification
            CriticalRouteLost = $criticalRouteLost
            Before = $prior
            After = $actual
            ExpectedAfter = $target
        }
    }

    [pscustomobject]@{ Scope = $before.Scope; Changes = @($changes) }
}
