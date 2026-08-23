# Conditional Access Graph adapter

`Save-CP365ConditionalAccessSnapshot` collects Microsoft Entra Conditional Access policy JSON and adds it to a ChangePack365 case as `before` or `after` evidence.

## Safety boundary

- Uses `GET /v1.0/identity/conditionalAccess/policies` only.
- Requests no write permission.
- Supports delegated Graph sessions in the MVP.
- Rejects a tenant or account whose fingerprint differs from the case contract.
- Keeps policy timestamps and identifiers because hiding them could conceal a real delta.

## Connect

The endpoint documentation currently identifies `Policy.Read.All` as its least-privileged delegated permission.

```powershell
Connect-MgGraph -Scopes 'Policy.Read.All' -UseDeviceAuthentication
Get-MgContext
```

The signed-in user must also hold a supported Entra role, such as Security Reader, Global Reader, Security Administrator, Conditional Access Administrator, or Global Secure Access Administrator.

## Collect

```powershell
$before = Save-CP365ConditionalAccessSnapshot -CasePath $case.Path -Phase before

# An approved change happens outside ChangePack365.

$after = Save-CP365ConditionalAccessSnapshot -CasePath $case.Path -Phase after
Compare-CP365Snapshot -CasePath $case.Path -BeforePath $before.Path -AfterPath $after.Path
```

Use `-PolicyId <guid>` to scope both snapshots to one policy.

## References

- [List Conditional Access policies](https://learn.microsoft.com/graph/api/conditionalaccessroot-list-policies)
- [Microsoft Graph PowerShell authentication](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands)
