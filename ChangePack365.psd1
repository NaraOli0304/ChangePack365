@{
    RootModule        = 'ChangePack365.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '44715626-9c3f-46e3-9d6e-cf472a0b2f0d'
    Author            = 'Nara Oliveira'
    Copyright         = '(c) 2026 Nara Oliveira. MIT License.'
    Description       = 'Tamper-evident change evidence packs for Microsoft 365 operations.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'New-CP365Case',
        'Get-CP365ContextFingerprint',
        'Confirm-CP365WriteContext',
        'Add-CP365Evidence',
        'Add-CP365GraphEvidenceRecord',
        'Compare-CP365Snapshot',
        'New-CP365StakeholderSummary',
        'Export-CP365HtmlReport',
        'Save-CP365ConditionalAccessSnapshot',
        'Invoke-CP365GraphTimeSlicedRead',
        'New-CP365GraphEvidenceRecord',
        'Test-CP365Ledger',
        'Test-CP365CasePackage',
        'Export-CP365Case'
    )
    PrivateData = @{
        PSData = @{
            Tags       = @('Microsoft365', 'Evidence', 'ChangeManagement', 'PowerShell', 'Audit')
            LicenseUri = 'https://opensource.org/license/mit'
            ProjectUri = 'https://github.com/NaraOli0304/ChangePack365'
        }
    }
}
