# Planned Intune change: evidence runbook

Use this workflow to document one approved Windows Update ring change. ChangePack365 collects evidence; the operator performs any separately approved configuration change through the normal administration process.

The project is an experimental MVP. The example below uses fictional identities, a fictional policy ID and an illustrative deferral change. Use it in a lab; it is not a recommendation to change a production update ring.

## 1. Define the operational change

Complete this record before collecting the change baseline:

| Item | Required detail |
| --- | --- |
| Change reference | Ticket, operational objective, approver and executor |
| Identity and target | Independently verified tenant, operator account, Global cloud and exact policy GUID |
| Intended delta | Exact property or assignment, current value and approved new value |
| Preserved settings | Assignment targets, exclusions and other properties that must remain unchanged |
| Population and timing | Intended pilot, affected-device count and UTC change window |
| Acceptance | Configuration checks plus the device/application checks and their owner |
| Rollback | Previous approved value/configuration, trigger, executor and decision deadline |

If the intended delta is not defined, keep the record as a draft. Do not create an empty change contract and treat a later change as approved.

A declared assignment is intended targeting. It does not prove current group membership, policy application, installation or successful business validation.

## 2. Prepare the evidence contract

Run from the repository root in PowerShell 7.2+. Establish and verify a delegated Global Graph session separately, with `DeviceManagementConfiguration.Read.All` and sufficient Intune access. The adapter validates the tenant/account fingerprint before reading; it does not authenticate or request consent.

Illustrative lab change: change `qualityUpdatesDeferralPeriodInDays` from `0` to `1`, preserving all assignments and policy identity. Replace every fictional input with the approved lab values. Use a fresh case ID and an internal evidence location outside the source checkout.

```powershell
$ErrorActionPreference = 'Stop'
Import-Module ./ChangePack365.psd1 -Force

$policyId = [guid]'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
$caseParameters = @{
    CaseId = 'LAB-CHG-001'
    Title = 'Lab: approved quality update deferral change'
    TenantId = '11111111-2222-4333-8444-555555555555'
    TenantDisplayName = 'Contoso Lab'
    Account = 'operator@contoso.example'
    Workload = @('IntuneWindowsUpdatePolicy')
    Mode = 'ReadOnly'
    RootPath = Join-Path ([IO.Path]::GetTempPath()) 'Contoso-ChangeEvidence'
    ExpectedChange = @(
        @{ path = '$.policy.qualityUpdatesDeferralPeriodInDays'; operation = 'Modified' }
    )
    ForbiddenChange = @(
        @{ path = '$.assignments*' }
        @{ path = '$.policy.id' }
        @{ path = '$.policy.@odata.type' }
    )
}
$case = New-CP365Case @caseParameters
```

Rules match flattened paths with PowerShell wildcard semantics; they are not a general JSONPath query language. Forbidden rules take precedence. Do not forbid `$.policy.*` while expecting a property under that same prefix to change.

The contract classifies paths and operations. It does **not** assert the approved old/new values, prove all expected changes occurred, or import the ticket approval into `approvals`. Keep the approved record alongside internal evidence and verify values explicitly.

Keep the evidence case in `ReadOnly` mode: it collects evidence of an external change. `ControlledWrite` is not required for these GET adapters and does not grant Intune permission.

## 3. Collect and check the baseline

```powershell
$before = Save-CP365IntuneUpdatePolicySnapshot -CasePath $case.Path -Phase before -PolicyId $policyId
$baseline = Get-Content -LiteralPath $before.Path -Raw | ConvertFrom-Json -Depth 100
if ($baseline.policy.qualityUpdatesDeferralPeriodInDays -ne 0) {
    throw 'The baseline differs from the approved lab starting value. Review the change record.'
}
if (-not (Test-CP365Ledger -CasePath $case.Path).Valid) {
    throw 'Baseline ledger verification failed.'
}
```

Check the actual policy and assignment targets against the approved population before the change. Collection or context errors stop this workflow; missing evidence is not a successful empty result.

Do not edit `contract.json` after collection to make observed differences match the plan. If the plan changes, retain this case and start a new one.

## 4. Perform the separately approved change

This is the operational handoff, outside ChangePack365. The named executor follows the approved method and window. Record completion time, result and any deviation in the change ticket.

This runbook contains no Graph write, policy reassignment, device synchronization or restart command.

## 5. Collect and assess the result

Run only after that separate action has completed.

```powershell
$after = Save-CP365IntuneUpdatePolicySnapshot -CasePath $case.Path -Phase after -PolicyId $policyId
$result = Compare-CP365Snapshot -CasePath $case.Path -BeforePath $before.Path -AfterPath $after.Path

$observed = Get-Content -LiteralPath $after.Path -Raw | ConvertFrom-Json -Depth 100
if ($observed.policy.qualityUpdatesDeferralPeriodInDays -ne 1) {
    throw 'The approved lab target value was not observed. Retain the evidence and review.'
}
if ($result.Summary.total -ne 1 -or $result.Summary.expected -ne 1 -or
    $result.Summary.unexpected -gt 0 -or $result.Summary.forbidden -gt 0) {
    throw 'The observed delta differs from this one-property lab contract. Review the saved diff.'
}
```

Even a source timestamp such as `lastModifiedDateTime` can appear as an unexpected delta. Inspect it; do not silently whitelist a broad policy prefix or rewrite the contract after the fact.

Zero differences are valid comparison output, but do not prove that a requested modification occurred. A wrong new value can still have an expected path classification. The explicit value and count checks above address those two limitations for this example.

Retain forbidden/unexpected results and stop acceptance pending review. Use the rollback decision in the approved record when its trigger is met. Document any approved rollback as a separate case linked to the original; do not overwrite the original after snapshot.

## 6. Report, export and verify

Generate the review artifacts after assessing the diff. Keep device/application acceptance separate from the configuration comparison.

```powershell
New-CP365StakeholderSummary -CasePath $case.Path
Export-CP365HtmlReport -CasePath $case.Path -Language 'pt-BR'

$bundle = Export-CP365Case -CasePath $case.Path
$verification = Test-CP365CasePackage -PackagePath $bundle.FullName
if (-not $verification.Valid) {
    throw "Internal package verification failed: $($verification.Status)"
}
$verification | Select-Object Status, FilesChecked, SignatureStatus, AuthenticityEstablished
```

The internal ZIP excludes the case's `public` report folder. Retain the HTML/summaries separately for review. It also excludes `artifacts`, preventing exported packages from recursively embedding earlier exports.

A valid unsigned package establishes internal integrity, not signer identity. If a trusted signing identity is required, use the [signed-manifest workflow](../README.md#signed-manifests) with an independently obtained expected thumbprint. Public redacted bundles currently return `Unsupported` from the verifier; internal validity is not a redaction or sharing approval.

Close the operational change only when both the reviewed configuration delta and the independently defined device/business acceptance are satisfied. Keep tenant exports and internal reports out of Git.

## References

- [Adapter scope and failure behavior](graph-intune-update-policy.md)
- [Change comparison implementation](../Public/Compare-CP365Snapshot.ps1)
- [Microsoft Graph: get Windows Update configuration](https://learn.microsoft.com/graph/api/intune-deviceconfig-windowsupdateforbusinessconfiguration-get?view=graph-rest-1.0)
- [Microsoft Graph: list device configuration assignments](https://learn.microsoft.com/graph/api/intune-deviceconfig-deviceconfigurationassignment-list?view=graph-rest-1.0)
