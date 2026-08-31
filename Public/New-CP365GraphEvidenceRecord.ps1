function New-CP365GraphEvidenceRecord {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Collection,

        [string]$OutputPath,

        [string]$TenantFingerprint,

        [string]$AccountFingerprint
    )

    function Get-RequiredManifestProperty {
        param(
            [Parameter(Mandatory)]$InputObject,
            [Parameter(Mandatory)][string]$Name
        )

        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) {
            throw "Collector manifest is missing required property '$Name'."
        }
        return $property.Value
    }

    if ([string]::IsNullOrWhiteSpace($Collection)) {
        throw 'Collection must not be empty or whitespace.'
    }

    $manifestItem = Get-Item -LiteralPath $ManifestPath -ErrorAction Stop
    if ($manifestItem.PSIsContainer) {
        throw 'ManifestPath must reference a file.'
    }
    if (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'ManifestPath must not reference a symbolic link or reparse point.'
    }

    $manifestFullPath = $manifestItem.FullName
    $manifestDirectory = Split-Path -Parent $manifestFullPath
    $manifest = Get-Content -LiteralPath $manifestFullPath -Raw |
        ConvertFrom-Json -Depth 100

    $queryFingerprint = [string](Get-RequiredManifestProperty -InputObject $manifest -Name 'queryFingerprint')
    $queryMode = [string](Get-RequiredManifestProperty -InputObject $manifest -Name 'queryMode')
    $collectedAt = [datetimeoffset](Get-RequiredManifestProperty -InputObject $manifest -Name 'collectedAtUtc')
    $windowStart = [datetimeoffset](Get-RequiredManifestProperty -InputObject $manifest -Name 'startUtc')
    $windowEnd = [datetimeoffset](Get-RequiredManifestProperty -InputObject $manifest -Name 'endUtc')
    $recordCount = [long](Get-RequiredManifestProperty -InputObject $manifest -Name 'uniqueRecordCount')
    $manifestComplete = [bool](Get-RequiredManifestProperty -InputObject $manifest -Name 'complete')

    if ($queryFingerprint -notmatch '^[A-Fa-f0-9]{16}$') {
        throw 'Collector manifest queryFingerprint must contain 16 hexadecimal characters.'
    }
    if ($queryMode -notin @('GET_ONLY', 'GET_BATCH', 'LOCAL_ONLY', 'OTHER_READ_ONLY')) {
        throw "Unsupported query mode '$queryMode'."
    }
    if ($windowEnd -le $windowStart) {
        throw 'Collector manifest endUtc must be later than startUtc.'
    }
    if ($recordCount -lt 0) {
        throw 'Collector manifest uniqueRecordCount must not be negative.'
    }

    $slices = @(Get-RequiredManifestProperty -InputObject $manifest -Name 'slices')
    $verifiedCheckpointCount = 0
    $incompleteSliceCount = 0

    foreach ($slice in $slices) {
        if ($slice.complete -ne $true) {
            $incompleteSliceCount++
            continue
        }

        $checkpointProperty = $slice.PSObject.Properties['checkpoint']
        $hashProperty = $slice.PSObject.Properties['checkpointSha256']
        if (
            $null -eq $checkpointProperty -or
            [string]::IsNullOrWhiteSpace([string]$checkpointProperty.Value) -or
            $null -eq $hashProperty -or
            [string]$hashProperty.Value -notmatch '^[A-Fa-f0-9]{64}$'
        ) {
            throw 'Every complete slice must include checkpoint and checkpointSha256.'
        }

        $checkpointItem = Get-Item -LiteralPath ([string]$checkpointProperty.Value) -ErrorAction Stop
        if ($checkpointItem.PSIsContainer) {
            throw 'A checkpoint path references a directory.'
        }
        if (($checkpointItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Checkpoint paths must not reference symbolic links or reparse points.'
        }

        $relativeCheckpoint = [IO.Path]::GetRelativePath(
            $manifestDirectory,
            $checkpointItem.FullName
        )
        $parentPrefix = '..' + [IO.Path]::DirectorySeparatorChar
        if (
            $relativeCheckpoint -eq '..' -or
            $relativeCheckpoint.StartsWith($parentPrefix, [StringComparison]::Ordinal)
        ) {
            throw 'Every checkpoint must remain inside the manifest directory.'
        }

        $actualHash = Get-CP365Hash -Path $checkpointItem.FullName
        $expectedHash = ([string]$hashProperty.Value).ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "Checkpoint hash mismatch for '$relativeCheckpoint'."
        }

        $verifiedCheckpointCount++
    }

    if ($manifestComplete -and ($slices.Count -eq 0 -or $incompleteSliceCount -gt 0)) {
        throw 'A complete collector manifest must contain only complete slices.'
    }

    $manifestHash = Get-CP365Hash -Path $manifestFullPath
    $identitySeed = @(
        $queryFingerprint.ToLowerInvariant(),
        $windowStart.ToUniversalTime().ToString('o'),
        $windowEnd.ToUniversalTime().ToString('o')
    ) -join "`n"
    $evidenceId = 'graph-' + (Get-CP365Hash -Text $identitySeed).Substring(0, 20)

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Join-Path $manifestDirectory "evidence-record_$queryFingerprint.json"
    }
    $outputFullPath = [IO.Path]::GetFullPath($OutputPath)
    if ($outputFullPath.Equals($manifestFullPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputPath must not overwrite the collector manifest.'
    }

    $outputDirectory = Split-Path -Parent $outputFullPath
    $artifactPath = [IO.Path]::GetRelativePath(
        $outputDirectory,
        $manifestFullPath
    ).Replace([IO.Path]::DirectorySeparatorChar, '/')

    $record = [ordered]@{
        evidenceId = $evidenceId
        source = 'MicrosoftGraph'
        collection = $Collection
        collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
        queryMode = $queryMode
        complete = $manifestComplete
        completenessNote = if ($manifestComplete) {
            $null
        } else {
            "Collector manifest reports $incompleteSliceCount incomplete slice(s)."
        }
        artifactPath = $artifactPath
        sha256 = $manifestHash
        recordCount = $recordCount
        failedObjectCount = $null
        windowStartUtc = $windowStart.ToUniversalTime().ToString('o')
        windowEndUtc = $windowEnd.ToUniversalTime().ToString('o')
        tenantFingerprint = if ([string]::IsNullOrWhiteSpace($TenantFingerprint)) { $null } else { $TenantFingerprint }
        accountFingerprint = if ([string]::IsNullOrWhiteSpace($AccountFingerprint)) { $null } else { $AccountFingerprint }
        notes = @("Verified $verifiedCheckpointCount checkpoint hash(es).")
        metadata = [ordered]@{
            queryFingerprint = $queryFingerprint.ToLowerInvariant()
            sliceCount = $slices.Count
            incompleteSliceCount = $incompleteSliceCount
            baseUri = $manifest.baseUri
            dateProperty = $manifest.dateProperty
            select = $manifest.select
            additionalFilter = $manifest.additionalFilter
            identityProperty = $manifest.identityProperty
        }
    }

    if (-not $PSCmdlet.ShouldProcess($outputFullPath, 'Write Graph evidence record')) {
        return
    }

    $null = New-Item -ItemType Directory -Path $outputDirectory -Force
    $record |
        ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $outputFullPath -Encoding utf8

    [pscustomobject]@{
        Path = $outputFullPath
        EvidenceId = $evidenceId
        ArtifactPath = $manifestFullPath
        Sha256 = $manifestHash
        Complete = $manifestComplete
        Record = [pscustomobject]$record
    }
}
