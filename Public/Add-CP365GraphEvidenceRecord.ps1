function Add-CP365GraphEvidenceRecord {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$CasePath,
        [Parameter(Mandatory)][string]$RecordPath,
        [ValidateSet('before', 'after', 'logs', 'rollback', 'artifacts')]
        [string]$Phase = 'artifacts'
    )

    function Get-RequiredProperty {
        param(
            [Parameter(Mandatory)]$InputObject,
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$ObjectName
        )

        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) {
            throw "$ObjectName is missing required property '$Name'."
        }
        $property.Value
    }

    function Assert-FileIsDirect {
        param(
            [Parameter(Mandatory)][IO.FileInfo]$Item,
            [Parameter(Mandatory)][string]$Description
        )

        if ($Item.PSIsContainer) {
            throw "$Description must reference a file."
        }
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description must not reference a symbolic link or reparse point."
        }
    }

    function Assert-PathIsInside {
        param(
            [Parameter(Mandatory)][string]$Parent,
            [Parameter(Mandatory)][string]$Child,
            [Parameter(Mandatory)][string]$Description
        )

        $relative = [IO.Path]::GetRelativePath($Parent, $Child)
        $parentPrefix = '..' + [IO.Path]::DirectorySeparatorChar
        if (
            $relative -eq '..' -or
            $relative.StartsWith($parentPrefix, [StringComparison]::Ordinal)
        ) {
            throw "$Description must remain inside '$Parent'."
        }
        $relative
    }

    $context = Get-CP365CaseContext -CasePath $CasePath
    $recordItem = Get-Item -LiteralPath $RecordPath -ErrorAction Stop
    Assert-FileIsDirect -Item $recordItem -Description 'RecordPath'

    $recordDirectory = Split-Path -Parent $recordItem.FullName
    $record = Get-Content -LiteralPath $recordItem.FullName -Raw |
        ConvertFrom-Json -Depth 100

    $evidenceId = [string](Get-RequiredProperty -InputObject $record -Name 'evidenceId' -ObjectName 'Evidence record')
    $source = [string](Get-RequiredProperty -InputObject $record -Name 'source' -ObjectName 'Evidence record')
    $collection = [string](Get-RequiredProperty -InputObject $record -Name 'collection' -ObjectName 'Evidence record')
    $collectedAt = [string](Get-RequiredProperty -InputObject $record -Name 'collectedAtUtc' -ObjectName 'Evidence record')
    $queryMode = [string](Get-RequiredProperty -InputObject $record -Name 'queryMode' -ObjectName 'Evidence record')
    $complete = Get-RequiredProperty -InputObject $record -Name 'complete' -ObjectName 'Evidence record'
    $artifactPath = [string](Get-RequiredProperty -InputObject $record -Name 'artifactPath' -ObjectName 'Evidence record')
    $expectedManifestHash = [string](Get-RequiredProperty -InputObject $record -Name 'sha256' -ObjectName 'Evidence record')

    if ($evidenceId -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'Evidence record evidenceId contains unsupported characters.'
    }
    if ($source -ne 'MicrosoftGraph') {
        throw "Unsupported evidence source '$source'."
    }
    if ([string]::IsNullOrWhiteSpace($collection)) {
        throw 'Evidence record collection must not be empty.'
    }
    $parsedCollectedAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($collectedAt, [ref]$parsedCollectedAt)) {
        throw 'Evidence record collectedAtUtc must be a valid date-time.'
    }
    if ($queryMode -notin @('GET_ONLY', 'GET_BATCH', 'LOCAL_ONLY', 'OTHER_READ_ONLY')) {
        throw "Unsupported query mode '$queryMode'."
    }
    if ($complete -isnot [bool]) {
        throw 'Evidence record complete must be a boolean.'
    }
    if ([IO.Path]::IsPathRooted($artifactPath)) {
        throw 'Evidence record artifactPath must be relative.'
    }
    if ($expectedManifestHash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Evidence record sha256 must contain 64 hexadecimal characters.'
    }

    $manifestFullPath = [IO.Path]::GetFullPath((Join-Path $recordDirectory $artifactPath))
    $null = Assert-PathIsInside `
        -Parent $recordDirectory `
        -Child $manifestFullPath `
        -Description 'Evidence record artifactPath'
    $manifestItem = Get-Item -LiteralPath $manifestFullPath -ErrorAction Stop
    Assert-FileIsDirect -Item $manifestItem -Description 'Evidence manifest'

    $actualManifestHash = Get-CP365Hash -Path $manifestItem.FullName
    if ($actualManifestHash -ne $expectedManifestHash.ToLowerInvariant()) {
        throw 'Evidence manifest hash does not match the evidence record.'
    }

    $manifest = Get-Content -LiteralPath $manifestItem.FullName -Raw |
        ConvertFrom-Json -Depth 100
    $manifestComplete = Get-RequiredProperty `
        -InputObject $manifest `
        -Name 'complete' `
        -ObjectName 'Collector manifest'
    if ($manifestComplete -isnot [bool] -or $manifestComplete -ne $complete) {
        throw 'Evidence record and collector manifest complete values must match.'
    }

    $manifestDirectory = Split-Path -Parent $manifestItem.FullName
    $slices = @(Get-RequiredProperty -InputObject $manifest -Name 'slices' -ObjectName 'Collector manifest')
    $checkpoints = [System.Collections.Generic.List[object]]::new()
    $checkpointIndex = 0

    foreach ($slice in $slices) {
        if ($slice.complete -ne $true) { continue }

        $checkpointPath = [string](Get-RequiredProperty -InputObject $slice -Name 'checkpoint' -ObjectName 'Complete slice')
        $checkpointHash = [string](Get-RequiredProperty -InputObject $slice -Name 'checkpointSha256' -ObjectName 'Complete slice')
        if ($checkpointHash -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'Complete slice checkpointSha256 must contain 64 hexadecimal characters.'
        }

        $checkpointFullPath = if ([IO.Path]::IsPathRooted($checkpointPath)) {
            [IO.Path]::GetFullPath($checkpointPath)
        } else {
            [IO.Path]::GetFullPath((Join-Path $manifestDirectory $checkpointPath))
        }
        $null = Assert-PathIsInside `
            -Parent $manifestDirectory `
            -Child $checkpointFullPath `
            -Description 'Checkpoint path'
        $checkpointItem = Get-Item -LiteralPath $checkpointFullPath -ErrorAction Stop
        Assert-FileIsDirect -Item $checkpointItem -Description 'Checkpoint path'

        $actualCheckpointHash = Get-CP365Hash -Path $checkpointItem.FullName
        if ($actualCheckpointHash -ne $checkpointHash.ToLowerInvariant()) {
            throw "Checkpoint hash mismatch for '$($checkpointItem.Name)'."
        }

        $checkpointIndex++
        $targetName = '{0}-checkpoint-{1:d4}-{2}' -f $evidenceId, $checkpointIndex, $checkpointItem.Name
        $slice.checkpoint = $targetName
        $checkpoints.Add([pscustomobject]@{
            Source = $checkpointItem.FullName
            Name = $targetName
            Sha256 = $actualCheckpointHash
        })
    }

    $manifestName = "$evidenceId-manifest.json"
    $recordName = "$evidenceId-record.json"
    $phasePath = Join-Path $context.Root $Phase
    $destinationNames = @($checkpoints.Name) + @($manifestName, $recordName)
    foreach ($name in $destinationNames) {
        $destination = Join-Path $phasePath $name
        if (Test-Path -LiteralPath $destination) {
            throw "Evidence destination '$destination' already exists; existing evidence will not be overwritten."
        }
    }

    if (-not $PSCmdlet.ShouldProcess($phasePath, "Register Graph evidence '$evidenceId'")) {
        return
    }

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "cp365-$([guid]::NewGuid().Guid)"
    try {
        $null = New-Item -ItemType Directory -Path $temporaryRoot -Force
        $portableManifestPath = Join-Path $temporaryRoot $manifestName
        $manifest |
            ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $portableManifestPath -Encoding utf8
        $portableManifestHash = Get-CP365Hash -Path $portableManifestPath

        $record.artifactPath = $manifestName
        $record.sha256 = $portableManifestHash
        $portableRecordPath = Join-Path $temporaryRoot $recordName
        $record |
            ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $portableRecordPath -Encoding utf8

        $addedCheckpoints = @(
            foreach ($checkpoint in $checkpoints) {
                Add-CP365Evidence `
                    -CasePath $context.Root `
                    -Phase $Phase `
                    -Path $checkpoint.Source `
                    -Name $checkpoint.Name `
                    -Confirm:$false
            }
        )
        $addedManifest = Add-CP365Evidence `
            -CasePath $context.Root `
            -Phase $Phase `
            -Path $portableManifestPath `
            -Name $manifestName `
            -Confirm:$false
        $addedRecord = Add-CP365Evidence `
            -CasePath $context.Root `
            -Phase $Phase `
            -Path $portableRecordPath `
            -Name $recordName `
            -Confirm:$false

        $registration = Write-CP365LedgerEvent `
            -CasePath $context.Root `
            -EventType 'GraphEvidenceRegistered' `
            -Payload @{
                phase = $Phase
                evidenceId = $evidenceId
                source = $source
                collection = $collection
                complete = $complete
                recordFile = "$Phase/$recordName"
                recordSha256 = $addedRecord.Sha256
                manifestFile = "$Phase/$manifestName"
                manifestSha256 = $addedManifest.Sha256
                checkpointCount = $addedCheckpoints.Count
            }

        [pscustomobject]@{
            EvidenceId = $evidenceId
            Phase = $Phase
            Complete = $complete
            RecordPath = $addedRecord.Path
            ManifestPath = $addedManifest.Path
            CheckpointPaths = @($addedCheckpoints.Path)
            LedgerEntryHash = $registration.entryHash
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }
}
