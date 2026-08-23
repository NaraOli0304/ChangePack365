function ConvertTo-CP365FlatMap {
    param(
        [AllowNull()][object]$InputObject,
        [string]$Prefix = '$',
        [hashtable]$Map = @{}
    )

    if ($null -eq $InputObject) {
        $Map[$Prefix] = 'null'
        return $Map
    }

    $properties = @(
        if ($InputObject -is [System.Collections.IDictionary]) {
            $InputObject.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $InputObject[$_] } }
        } elseif ($InputObject -is [pscustomobject]) {
            $InputObject.PSObject.Properties
        }
    )

    if ($properties.Count) {
        foreach ($property in $properties) {
            ConvertTo-CP365FlatMap -InputObject $property.Value -Prefix "$Prefix.$($property.Name)" -Map $Map | Out-Null
        }
        return $Map
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isnot [string])) {
        $index = 0
        foreach ($item in $InputObject) {
            ConvertTo-CP365FlatMap -InputObject $item -Prefix "$Prefix[$index]" -Map $Map | Out-Null
            $index++
        }
        if ($index -eq 0) { $Map[$Prefix] = '[]' }
        return $Map
    }

    $Map[$Prefix] = ConvertTo-CP365CanonicalJson $InputObject
    return $Map
}
