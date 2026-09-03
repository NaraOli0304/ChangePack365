function Invoke-CP365GraphTimeSlicedRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^https://graph\.microsoft\.com/')]
        [string]$BaseUri,

        [Parameter(Mandatory)]
        [datetime]$StartUtc,

        [Parameter(Mandatory)]
        [datetime]$EndUtc,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_.]*$')]
        [string]$DateProperty,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [ValidateRange(1, 1440)]
        [int]$InitialWindowMinutes = 60,

        [ValidateRange(1, 60)]
        [int]$MinimumWindowMinutes = 5,

        [ValidateRange(1, 999)]
        [int]$Top = 999,

        [string]$Select,

        [string]$AdditionalFilter,

        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_.]*$')]
        [string]$IdentityProperty = 'id',

        [ValidateRange(1, 10)]
        [int]$MaxTransientAttempts = 4,

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($EndUtc -le $StartUtc) {
        throw 'EndUtc must be later than StartUtc.'
    }

    if ($MinimumWindowMinutes -gt $InitialWindowMinutes) {
        throw 'MinimumWindowMinutes cannot exceed InitialWindowMinutes.'
    }

    $parsedBaseUri = [uri]$BaseUri
    if ($parsedBaseUri.Scheme -ne 'https' -or $parsedBaseUri.Host -ne 'graph.microsoft.com') {
        throw 'BaseUri must use https://graph.microsoft.com/.'
    }
    if (-not [string]::IsNullOrWhiteSpace($parsedBaseUri.Query)) {
        throw 'BaseUri must not contain a query string. Use Select and AdditionalFilter parameters instead.'
    }

    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        throw 'Invoke-MgGraphRequest is required. Connect to Microsoft Graph before running this collector.'
    }

    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force

    $results = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $manifest = [System.Collections.Generic.List[object]]::new()

    $queryContract = @(
        $BaseUri.TrimEnd('/'),
        $DateProperty,
        $Select,
        $AdditionalFilter,
        [string]$Top,
        $IdentityProperty
    ) -join "`n"

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $queryHashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($queryContract))
    }
    finally {
        $sha.Dispose()
    }
    $queryFingerprint = (-join ($queryHashBytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)

    function Get-CP365HttpStatusFromError {
        param([Parameter(Mandatory)]$ErrorRecord)

        $message = [string]$ErrorRecord.Exception.Message
        if ($message -match 'HTTP/[^ ]+\s+(\d{3})') {
            return [int]$Matches[1]
        }
        if ($message -match '\b(410|429|500|502|503|504)\b') {
            return [int]$Matches[1]
        }
        return $null
    }

    function Get-CP365RetryAfterSeconds {
        param([Parameter(Mandatory)]$ErrorRecord)

        $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
        if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) {
            return $null
        }

        $headersProperty = $responseProperty.Value.PSObject.Properties['Headers']
        if ($null -eq $headersProperty -or $null -eq $headersProperty.Value) {
            return $null
        }

        $headers = $headersProperty.Value
        $rawValue = $null
        if ($headers -is [System.Collections.IDictionary]) {
            if ($headers.Contains('Retry-After')) {
                $rawValue = $headers['Retry-After']
            }
        }
        else {
            $retryAfterProperty = $headers.PSObject.Properties['RetryAfter']
            if ($null -ne $retryAfterProperty) {
                $retryAfter = $retryAfterProperty.Value
                if ($null -ne $retryAfter) {
                    $deltaProperty = $retryAfter.PSObject.Properties['Delta']
                    if ($null -ne $deltaProperty -and $null -ne $deltaProperty.Value) {
                        return [int][math]::Ceiling(([timespan]$deltaProperty.Value).TotalSeconds)
                    }

                    $dateProperty = $retryAfter.PSObject.Properties['Date']
                    if ($null -ne $dateProperty -and $null -ne $dateProperty.Value) {
                        $remaining = ([datetimeoffset]$dateProperty.Value) - [datetimeoffset]::UtcNow
                        return [int][math]::Max(0, [math]::Ceiling($remaining.TotalSeconds))
                    }

                    $rawValue = $retryAfter
                }
            }

            if ($null -eq $rawValue) {
                $rawHeaderProperty = $headers.PSObject.Properties['Retry-After']
                if ($null -ne $rawHeaderProperty) {
                    $rawValue = $rawHeaderProperty.Value
                }
            }
        }

        $rawValue = @($rawValue)[0]
        $seconds = 0
        if (
            $null -ne $rawValue -and
            [int]::TryParse(
                [string]$rawValue,
                [System.Globalization.NumberStyles]::Integer,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$seconds
            ) -and
            $seconds -ge 0
        ) {
            return $seconds
        }

        $retryDate = [datetimeoffset]::MinValue
        if (
            $null -ne $rawValue -and
            [datetimeoffset]::TryParse(
                [string]$rawValue,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal,
                [ref]$retryDate
            )
        ) {
            $remaining = $retryDate - [datetimeoffset]::UtcNow
            return [int][math]::Max(0, [math]::Ceiling($remaining.TotalSeconds))
        }

        return $null
    }

    function Get-CP365ObjectPropertyValue {
        param(
            [Parameter(Mandatory)]$InputObject,
            [Parameter(Mandatory)][string]$PropertyName
        )

        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($PropertyName)) {
                return $InputObject[$PropertyName]
            }
            return $null
        }

        $property = $InputObject.PSObject.Properties[$PropertyName]
        if ($null -ne $property) {
            return $property.Value
        }

        return $null
    }

    function Add-CP365ResultIfUnique {
        param([Parameter(Mandatory)]$Item)

        $identity = [string](Get-CP365ObjectPropertyValue -InputObject $Item -PropertyName $IdentityProperty)
        if ([string]::IsNullOrWhiteSpace($identity)) {
            $results.Add($Item)
            return
        }

        if ($seen.Add($identity)) {
            $results.Add($Item)
        }
    }

    function Invoke-CP365Slice {
        param(
            [Parameter(Mandatory)][datetime]$SliceStart,
            [Parameter(Mandatory)][datetime]$SliceEnd
        )

        $tag = '{0}_{1}_{2}' -f $queryFingerprint, $SliceStart.ToUniversalTime().ToString('yyyyMMdd-HHmmss'), $SliceEnd.ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $checkpointPath = Join-Path $OutputDirectory ("slice_$tag.jsonl")
        $metaPath = Join-Path $OutputDirectory ("slice_$tag.meta.json")

        if ((Test-Path $checkpointPath) -and (Test-Path $metaPath)) {
            $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
            if (($meta.complete -eq $true) -and ([string]$meta.queryFingerprint -eq $queryFingerprint)) {
                foreach ($line in Get-Content -LiteralPath $checkpointPath) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $item = $line | ConvertFrom-Json
                    Add-CP365ResultIfUnique -Item $item
                }
                $manifest.Add($meta)
                return
            }
        }

        $startText = $SliceStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $endText = $SliceEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $filter = "$DateProperty ge $startText and $DateProperty lt $endText"
        if (-not [string]::IsNullOrWhiteSpace($AdditionalFilter)) {
            $filter = "($filter) and ($AdditionalFilter)"
        }

        $query = '?$filter=' + [uri]::EscapeDataString($filter) + '&$top=' + $Top
        if (-not [string]::IsNullOrWhiteSpace($Select)) {
            $query += '&$select=' + [uri]::EscapeDataString($Select)
        }
        $uri = $BaseUri.TrimEnd('?') + $query

        $sliceRows = [System.Collections.Generic.List[object]]::new()
        $pageCount = 0
        $requestCount = 0

        try {
            do {
                $page = $null
                for ($attempt = 1; $attempt -le $MaxTransientAttempts; $attempt++) {
                    try {
                        $requestCount++
                        $page = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
                        break
                    }
                    catch {
                        $status = Get-CP365HttpStatusFromError -ErrorRecord $_

                        if ($status -eq 410) {
                            throw
                        }

                        if (($status -in @(429, 500, 502, 503, 504)) -and ($attempt -lt $MaxTransientAttempts)) {
                            $retryAfterSeconds = if ($status -eq 429) {
                                Get-CP365RetryAfterSeconds -ErrorRecord $_
                            }
                            else {
                                $null
                            }
                            $delay = if ($null -ne $retryAfterSeconds) {
                                $retryAfterSeconds
                            }
                            else {
                                [math]::Min(30, [math]::Pow(2, $attempt))
                            }
                            Start-Sleep -Seconds $delay
                            continue
                        }

                        throw
                    }
                }

                if ($null -eq $page) {
                    throw 'Graph page was not returned.'
                }

                $pageCount++
                foreach ($item in @($page['value'])) {
                    $sliceRows.Add($item)
                }

                $nextLink = [string]$page['@odata.nextLink']
                if (-not [string]::IsNullOrWhiteSpace($nextLink)) {
                    $parsedNextLink = [uri]$nextLink
                    if (
                        -not $parsedNextLink.IsAbsoluteUri -or
                        $parsedNextLink.Scheme -ne 'https' -or
                        $parsedNextLink.Host -ne 'graph.microsoft.com'
                    ) {
                        throw 'Graph pagination nextLink must use https://graph.microsoft.com/.'
                    }
                }
                $uri = $nextLink
            }
            while (-not [string]::IsNullOrWhiteSpace($uri))
        }
        catch {
            $status = Get-CP365HttpStatusFromError -ErrorRecord $_
            $durationMinutes = ($SliceEnd - $SliceStart).TotalMinutes

            if ($status -eq 410) {
                $halfDuration = [timespan]::FromTicks([long](($SliceEnd - $SliceStart).Ticks / 2))
                $mid = $SliceStart + $halfDuration
                $leftMinutes = ($mid - $SliceStart).TotalMinutes
                $rightMinutes = ($SliceEnd - $mid).TotalMinutes

                if (($leftMinutes -ge $MinimumWindowMinutes) -and ($rightMinutes -ge $MinimumWindowMinutes)) {
                    Invoke-CP365Slice -SliceStart $SliceStart -SliceEnd $mid
                    Invoke-CP365Slice -SliceStart $mid -SliceEnd $SliceEnd
                    return
                }
            }

            $failureMeta = [ordered]@{
                queryFingerprint = $queryFingerprint
                startUtc = $SliceStart.ToUniversalTime().ToString('o')
                endUtc = $SliceEnd.ToUniversalTime().ToString('o')
                windowMinutes = $durationMinutes
                complete = $false
                pageCount = $pageCount
                requestCount = $requestCount
                httpStatus = $status
                error = [string]$_.Exception.Message
            }
            $failureMeta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metaPath -Encoding UTF8
            $manifest.Add([pscustomobject]$failureMeta)
            throw
        }

        Set-Content -LiteralPath $checkpointPath -Value '' -Encoding UTF8
        foreach ($item in $sliceRows) {
            $item | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath $checkpointPath -Encoding UTF8
            Add-CP365ResultIfUnique -Item $item
        }

        $successMeta = [ordered]@{
            queryFingerprint = $queryFingerprint
            startUtc = $SliceStart.ToUniversalTime().ToString('o')
            endUtc = $SliceEnd.ToUniversalTime().ToString('o')
            windowMinutes = ($SliceEnd - $SliceStart).TotalMinutes
            complete = $true
            recordCount = $sliceRows.Count
            pageCount = $pageCount
            requestCount = $requestCount
            checkpoint = $checkpointPath
            checkpointSha256 = Get-CP365Hash -Path $checkpointPath
        }
        $successMeta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metaPath -Encoding UTF8
        $manifest.Add([pscustomobject]$successMeta)
    }

    $cursor = $StartUtc.ToUniversalTime()
    $final = $EndUtc.ToUniversalTime()

    $collectionError = $null
    try {
        while ($cursor -lt $final) {
            $sliceEnd = $cursor.AddMinutes($InitialWindowMinutes)
            if ($sliceEnd -gt $final) { $sliceEnd = $final }
            Invoke-CP365Slice -SliceStart $cursor -SliceEnd $sliceEnd
            $cursor = $sliceEnd
        }
    }
    catch {
        $collectionError = $_
    }

    $manifestPath = Join-Path $OutputDirectory ("collection-manifest_$queryFingerprint.json")
    $summary = [ordered]@{
        collectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        queryMode = 'GET_ONLY'
        queryFingerprint = $queryFingerprint
        baseUri = $BaseUri
        dateProperty = $DateProperty
        select = $Select
        additionalFilter = $AdditionalFilter
        identityProperty = $IdentityProperty
        startUtc = $StartUtc.ToUniversalTime().ToString('o')
        endUtc = $EndUtc.ToUniversalTime().ToString('o')
        complete = (($manifest.Count -gt 0) -and (@($manifest | Where-Object { $_.complete -ne $true }).Count -eq 0))
        uniqueRecordCount = $results.Count
        sliceCount = $manifest.Count
        slices = @($manifest)
    }
    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    if ($null -ne $collectionError) {
        $collectionError.Exception.Data['ManifestPath'] = $manifestPath
        throw $collectionError
    }

    if ($PassThru) {
        return [pscustomobject]@{
            Records = @($results)
            Manifest = [pscustomobject]$summary
            ManifestPath = $manifestPath
        }
    }

    return [pscustomobject]@{
        Complete = $summary.complete
        RecordCount = $results.Count
        SliceCount = $manifest.Count
        ManifestPath = $manifestPath
        QueryMode = 'GET_ONLY'
        QueryFingerprint = $queryFingerprint
    }
}
