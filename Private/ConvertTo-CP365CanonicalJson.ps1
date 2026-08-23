function ConvertTo-CP365CanonicalObject {
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($InputObject.Keys | Sort-Object { [string]$_ })) {
            $ordered[[string]$key] = ConvertTo-CP365CanonicalObject $InputObject[$key]
        }
        return $ordered
    }

    if ($InputObject -is [pscustomobject]) {
        $ordered = [ordered]@{}
        foreach ($property in @($InputObject.PSObject.Properties | Sort-Object Name)) {
            $ordered[$property.Name] = ConvertTo-CP365CanonicalObject $property.Value
        }
        return $ordered
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isnot [string])) {
        return @($InputObject | ForEach-Object { ConvertTo-CP365CanonicalObject $_ })
    }

    return $InputObject
}

function ConvertTo-CP365CanonicalJson {
    param([AllowNull()][object]$InputObject)
    ConvertTo-CP365CanonicalObject $InputObject | ConvertTo-Json -Depth 100 -Compress
}
