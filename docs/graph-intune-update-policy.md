# Intune Windows Update policy snapshots

`Save-CP365IntuneUpdatePolicySnapshot` captures one Windows Update ring policy and all its declared assignments as `before` or `after` evidence. It reuses the case fingerprint, comparison engine, ledger, and exporters.

## Scope and permissions

- PowerShell 7.2+ and Microsoft Graph PowerShell authentication commands.
- Delegated work/school session in the Global Graph environment, matching the case tenant and account.
- `DeviceManagementConfiguration.Read.All`, consented separately by an authorized administrator. The adapter neither connects nor requests consent.
- An active Intune license and sufficient Intune access for the signed-in account; consent alone does not guarantee access.
- A mandatory policy GUID whose response type is `#microsoft.graph.windowsUpdateForBusinessConfiguration`.
- Only `GET /v1.0/deviceManagement/deviceConfigurations/{id}` and the policy's `/assignments` collection are read. Continuation links must stay on that same collection at `https://graph.microsoft.com`.

This is the update-ring subset of Intune policy evidence. Settings Catalog, feature-update policies, driver policies, compliance policies, managed-device inventory, effective group membership, and device application status are outside this adapter.

## Example

Create a case with the intended tenant and operator before collecting. The placeholders below must be replaced with independently verified values.

```powershell
Connect-MgGraph -Scopes 'DeviceManagementConfiguration.Read.All' -UseDeviceAuthentication

$before = Save-CP365IntuneUpdatePolicySnapshot -CasePath $case.Path -Phase before -PolicyId '<policy-guid>'

# A separately approved change occurs outside ChangePack365.

$after = Save-CP365IntuneUpdatePolicySnapshot -CasePath $case.Path -Phase after -PolicyId '<policy-guid>'
Compare-CP365Snapshot -CasePath $case.Path -BeforePath $before.Path -AfterPath $after.Path
```

The snapshot contains the policy response, including source timestamps and identifiers, and assignments sorted by ID. The ledger records collection time, policy ID, assignment count, and the verified context fingerprint. Preserve internal evidence confidentiality and review shared exports before distributing them.

## Failure and interpretation

Empty successful assignments remain an empty array. Missing/malformed collections, unsupported policy types, mismatched IDs, duplicate assignment IDs, cyclic or out-of-scope continuation links, and Graph errors terminate collection before any new snapshot or success event is written. A later-page error is never converted into an empty successful result. The adapter adds no retry/checkpoint layer; any throttling or transient error that escapes the SDK is propagated. Retry the collection explicitly after addressing the cause.

Local file/ledger failures are reported as errors and retain the existing evidence writer's behavior; this adapter does not introduce a multi-file transaction.

Assignments describe intended targeting. They do not establish group membership, applicability, compliance, delivery, or successful installation on any device. Compare device-side status and logs separately when those are the question.

## References

- [Get windowsUpdateForBusinessConfiguration](https://learn.microsoft.com/graph/api/intune-deviceconfig-windowsupdateforbusinessconfiguration-get?view=graph-rest-1.0)
- [List deviceConfigurationAssignments](https://learn.microsoft.com/graph/api/intune-deviceconfig-deviceconfigurationassignment-list?view=graph-rest-1.0)
