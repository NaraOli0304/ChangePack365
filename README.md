# ChangePack365

[![test](https://github.com/NaraOli0304/ChangePack365/actions/workflows/test.yml/badge.svg)](https://github.com/NaraOli0304/ChangePack365/actions/workflows/test.yml)
[![PowerShell 7.2+](https://img.shields.io/badge/PowerShell-7.2%2B-5391FE?logo=powershell)](https://learn.microsoft.com/powershell/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Make the change. Prove exactly what happened.**

ChangePack365 is a PowerShell toolkit for tamper-evident Microsoft 365 change evidence. It does not try to become another posture scanner, baseline engine, or automatic remediator. It wraps the operational change itself: target confirmation, declared intent, before/after evidence, delta classification, privacy-safe sharing, and a verifiable chain of custody.

> Status: experimental MVP. Use fictional or lab data until the project reaches a stable release.

## Why it is different

Most Microsoft 365 tools answer one of two questions: *What is misconfigured?* or *How do I fix it?* ChangePack365 answers the question that appears after an approved change:

> Can you prove that the intended property changed, forbidden properties did not change, and the evidence was not edited afterward?

The MVP introduces five opinionated controls:

1. **Tenant fingerprint** — tenant, account, and cloud become a short visual fingerprint. A mismatched identity cannot unlock a controlled-write session.
2. **Change contract** — expected and forbidden JSON paths are declared before execution. Every other delta is unexpected by default.
3. **Hash-chained ledger** — each evidence event points to the previous event. Editing history breaks validation.
4. **Dual evidence packs** — internal output keeps full fidelity; public output pseudonymizes UPNs, GUIDs, and IPv4 addresses consistently within the case.
5. **Honest results** — unexpected and forbidden deltas remain visible. The tool does not turn incomplete evidence into a green score.
6. **Fact-bound summaries** — PT-BR, Spanish, and English stakeholder notes are rendered from the same structured delta, without asking an AI to invent impact or certainty.

## What it is not

- A replacement for Maester, Microsoft365DSC, TenantBaseline, Hawk, or Microsoft Purview.
- A tenant-wide assessment product.
- A permission broker.
- An excuse to run production changes without approval and rollback planning.

## Quick demo

Requirements: PowerShell 7.2 or newer.

```powershell
git clone https://github.com/NaraOli0304/ChangePack365.git
cd ChangePack365
pwsh ./examples/demo.ps1
```

The demo uses a fictional tenant and creates:

```text
DEMO-001/
├── contract.json
├── ledger.jsonl
├── before/
├── after/
├── diff/
├── rollback/
└── artifacts/
    ├── DEMO-001-internal.zip
    └── DEMO-001-public.zip
```

## Core workflow

```powershell
Import-Module ./ChangePack365.psd1 -Force

$case = New-CP365Case `
  -CaseId 'CHG-2026-001' `
  -Title 'Enable Conditional Access pilot policy' `
  -TenantId '11111111-2222-4333-8444-555555555555' `
  -TenantDisplayName 'Contoso Demo' `
  -Account 'operator@contoso.example' `
  -Workload EntraID `
  -Mode ReadOnly

Add-CP365Evidence -CasePath $case.Path -Phase before -Path ./before.json
Add-CP365Evidence -CasePath $case.Path -Phase after -Path ./after.json

$result = Compare-CP365Snapshot `
  -CasePath $case.Path `
  -BeforePath ./before.json `
  -AfterPath ./after.json

New-CP365StakeholderSummary -CasePath $case.Path

Test-CP365Ledger -CasePath $case.Path
Export-CP365Case -CasePath $case.Path
Export-CP365Case -CasePath $case.Path -Public
```

## Safety model

The default mode is `ReadOnly`. `ControlledWrite` does not perform a Microsoft 365 change by itself; it only unlocks the surrounding evidence session after:

- the observed tenant/account fingerprint matches the contract;
- the operator types the exact fingerprint phrase;
- the confirmation is written to the ledger.

This separation is deliberate. Adapters for Graph, Exchange Online, and Intune will remain independently reviewable.

## Roadmap

- [x] Provider-neutral evidence cases
- [x] Context fingerprint
- [x] Expected/forbidden/unexpected delta classification
- [x] Hash-chained ledger validation
- [x] Internal and privacy-safe public bundles
- [ ] Signed manifests with a user certificate
- [ ] Graph snapshot adapter for Conditional Access
- [ ] Exchange Online DLP rule adapter
- [ ] Intune device/policy adapter
- [x] PT-BR, ES, and EN stakeholder summaries generated from structured facts
- [x] GitHub Actions and Pester matrix
- [x] JSON Schema for the change contract

## Design rule

ChangePack365 should integrate with mature assessment tools instead of copying them. The project owns the operational evidence lifecycle; providers own data collection.

## License

MIT © 2026 Nara Oliveira
