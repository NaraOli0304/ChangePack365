function Protect-CP365Text {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Salt
    )

    $patterns = [ordered]@{
        UPN  = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
        GUID = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b'
        IPv4 = '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b'
    }

    $result = $Text
    foreach ($kind in $patterns.Keys) {
        $result = [regex]::Replace($result, $patterns[$kind], {
            param($match)
            $token = Get-CP365Hash -Text "$Salt|$($match.Value.ToLowerInvariant())"
            "<$kind-$($token.Substring(0, 10))>"
        })
    }
    return $result
}
