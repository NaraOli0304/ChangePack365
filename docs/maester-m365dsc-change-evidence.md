# Maester and Microsoft365DSC evidence for an Entra change

Use this with a **fictional or lab tenant** while ChangePack365 remains an experimental MVP. The approved change itself is outside this runbook. Collection is read-only. Use a separate internal working directory; never commit tenant exports, reports, or the case directory.

## What each result proves

| Source | Scope and format | Use in the case |
| --- | --- | --- |
| ChangePack365 Graph adapter | One Conditional Access policy by ID (or all policies), JSON before/after | Classify declared, forbidden, and unexpected property deltas with `Compare-CP365Snapshot`. |
| Maester stable 2.x | Conditional Access tests selected with `-Tag CA`, report files | Record the regression result before and after. A passing test does not prove that a specific user was challenged for MFA. Compare the same test IDs, status, and applicability in both runs. |
| Microsoft365DSC | Selected configuration components, generated PowerShell `.ps1` | Preserve a wider configuration export when the change touches named locations or other related components. Review the exported content manually. The generic JSON comparator does not parse DSC PowerShell. |

Keep the Maester module and test set at the same reviewed stable version for both runs. Maester 3.0 preview has a different test engine and selector semantics; evaluate it separately, without mixing its results into the same regression comparison. Record the module versions, actual test selection, timestamps, tenant, account, and any skipped or errored tests. Microsoft365DSC exports all instances of a selected component unless a supported filter narrows it; the component selection alone is not a single-policy selector.

## Example collection

Run on a trusted operator workstation with a read-only account. Replace all example values locally. Confirm the signed-in tenant/account matches the case contract before collecting Maester or DSC evidence; the Graph adapter enforces this check for its own snapshots, but generic `Add-CP365Evidence` does not verify third-party provenance.

```powershell
Import-Module ./ChangePack365.psd1 -Force

$case = New-CP365Case `
  -CaseId 'CHG-LAB-001' `
  -Title 'Conditional Access lab change' `
  -TenantId '11111111-2222-4333-8444-555555555555' `
  -TenantDisplayName 'Contoso Lab' `
  -Account 'operator@contoso.example' `
  -Workload EntraID `
  -Mode ReadOnly `
  -ExpectedChange @(@{ path = 'state'; operation = 'Modified' }) `
  -ForbiddenChange @(@{ path = 'conditions.*'; operation = 'Modified' })

Connect-MgGraph -Scopes 'Policy.Read.All' -UseDeviceAuthentication
Get-MgContext
$before = Save-CP365ConditionalAccessSnapshot `
  -CasePath $case.Path -Phase before -PolicyId '<lab-policy-guid>'
```

Declare paths and operations from the **actual adapter JSON structure** before a real change. The above contract values are only an illustration, not a recommended production policy contract. Capture the intended scope and rollback in the ticket.

For Maester 2.x, use the installed test folder from the existing pilot. Verify the command and module version in the operator session, then run the same selection on both sides. Output is stored outside Git and inside the case after provenance review.

```powershell
Get-Module Maester -ListAvailable | Select-Object Name, Version, Path
$env:MAESTER_DISABLE_TELEMETRY = '1'
Connect-Maester
Invoke-Maester -Path '<existing-maester-test-folder>' -Tag CA `
  -OutputFolder '<private-workdir>/maester-before' -NonInteractive
```

If the pilot uses custom tests, pin the same test folder revision as well. Select the generated report and result JSON files, inspect the tenant/account and completeness, and attach them individually with unique names:

```powershell
Add-CP365Evidence -CasePath $case.Path -Phase before `
  -Path '<private-workdir>/maester-before/<result>.json' -Name 'maester-before.json'
Add-CP365Evidence -CasePath $case.Path -Phase before `
  -Path '<private-workdir>/maester-before/<report>.html' -Name 'maester-before.html'
```

Optional targeted DSC export when the change touches multiple configuration components:

```powershell
Get-Module Microsoft365DSC -ListAvailable | Select-Object Name, Version, Path
# Authenticate through the approved read-only method for these components.
Export-M365DSCConfiguration `
  -Components @('AADConditionalAccessPolicy', 'AADNamedLocationPolicy') `
  -Path '<private-workdir>/dsc-before' -FileName 'config-before.ps1'
Add-CP365Evidence -CasePath $case.Path -Phase before `
  -Path '<private-workdir>/dsc-before/config-before.ps1'
```

Check the installed Microsoft365DSC version's component catalog and required permissions before running. If the version calls a component differently, use its supported name and record that choice. The export is generated PowerShell; **do not execute it** as part of evidence collection. Inspect it for credentials, token replacements, and sensitive configuration before sharing.

After the separately authorized change, repeat the Graph snapshot, the **same Maester selection**, and any DSC export with `after` paths and names:

```powershell
$after = Save-CP365ConditionalAccessSnapshot `
  -CasePath $case.Path -Phase after -PolicyId '<lab-policy-guid>'
$delta = Compare-CP365Snapshot `
  -CasePath $case.Path -BeforePath $before.Path -AfterPath $after.Path
$delta.Summary
Test-CP365Ledger -CasePath $case.Path
$internal = Export-CP365Case -CasePath $case.Path
Test-CP365CasePackage -PackagePath $internal.FullName
```

Attach the after Maester and DSC files with `Add-CP365Evidence -Phase after` before the final ledger check and internal export. If any test is skipped, fails to connect, or a DSC component is missing, record the limitation as incomplete evidence. Review both the JSON delta and Maester outcome; a clean policy diff and a passing test suite answer different questions.

## Sharing boundary

`Add-CP365Evidence` hashes and copies files, but it does not verify which tenant produced a third-party report. `Export-CP365Case -Public` applies limited text substitutions and cannot guarantee safe redaction of arbitrary Maester HTML/JSON or DSC PowerShell. Keep these raw reports in the **internal** case bundle. Do not publish or email an automatic public bundle containing them without a separate file-by-file privacy review.

## References

- [ChangePack365 Conditional Access adapter](graph-conditional-access.md)
- [Maester version installation and pinning](https://maester.dev/docs/installation)
- [Maester 2.x tags and 3.0 preview mapping](https://maester.dev/docs/tests/tags)
- [Maester results and telemetry](https://maester.dev/docs/faq)
- [Microsoft365DSC Export-M365DSCConfiguration](https://microsoft365dsc.com/user-guide/cmdlets/Export-M365DSCConfiguration/)
