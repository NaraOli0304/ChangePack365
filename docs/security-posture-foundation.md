# Internal security posture foundation

This document describes a safe foundation for building internal Microsoft 365 / Entra / Intune security posture workflows without turning ChangePack365 into an autonomous scanner or remediator.

## Design intent

ChangePack365 remains responsible for evidence lifecycle, integrity, privacy-safe sharing, and proof of approved operational changes. Security posture logic should consume structured evidence and produce structured findings. The two concerns should remain separable.

```text
Microsoft Graph / local exports
        |
        v
Read-only collectors
        |
        v
Normalized evidence records
        |
        +--> correlation (user/group/device/role/policy/sign-in)
        |
        v
Structured findings
        |
        v
ChangePack365 evidence / stakeholder reporting
```

## Core principles

1. **Read-only by default** — collectors must not modify tenant state.
2. **No third-party data path** — production tenant evidence stays in approved internal storage.
3. **Fact-bound analysis** — distinguish facts, inferences, hypotheses, and unknowns.
4. **Completeness is explicit** — a failed object, expired token, or incomplete time window must remain visible.
5. **Resume instead of restart** — large jobs checkpoint results and continue safely.
6. **Deterministic evidence** — normalize, hash, and preserve timestamps and collection context.
7. **Security effect requires proof** — names such as MFA, Admin, Exception, Restricted, or Compliant are discovery signals only until actual assignments and controls are verified.

## Resilient Graph reads

`Invoke-CP365GraphTimeSlicedRead` is the first reusable read collector. It is intended for high-volume Graph resources with a timestamp property, such as sign-in logs.

Capabilities:

- Microsoft Graph URL allow-list validation;
- GET-only requests;
- fixed time windows;
- checkpoint per completed slice;
- resume from existing completed checkpoints;
- exponential retry for 429 and transient 5xx responses;
- automatic subdivision of a time slice after `410 Gone` / expired skip token;
- configurable minimum slice size;
- JSONL evidence output;
- identity-based deduplication;
- collection manifest with completeness and record counts.

A `410` is not converted into success. If the collector reaches the configured minimum time window and Graph still cannot complete pagination, the slice remains incomplete and the call fails visibly.

## Evidence schema

`schemas/evidence-record.schema.json` defines a normalized evidence record. Important fields include:

- source and collection;
- collection timestamp;
- query mode;
- completeness status;
- record/failure counts;
- original time window;
- artifact path;
- SHA256;
- optional tenant/account fingerprints.

## Finding schema

`schemas/security-finding.schema.json` defines a finding independently of any specific scanner. It captures:

- stable finding ID;
- severity and confidence;
- affected population;
- evidence references;
- FACT / INFERENCE / HYPOTHESIS fields;
- root cause;
- limitations;
- recommendation;
- optional owner, status, timestamps, and analytical score.

`analyticalScore` is explicitly not Microsoft Identity Protection risk.

## Suggested future modules

The next safe increments are:

- normalized user/group/device/policy/sign-in entities;
- correlation indexes using hashtables rather than repeated linear scans;
- Conditional Access include/exclude effect mapping;
- privileged-role / PIM evidence adapters;
- Intune ownership/compliance evidence adapters;
- stale-account and service/shared-account classifiers;
- finding rules implemented as deterministic PowerShell, not free-form AI decisions;
- report generation from structured findings;
- Pester fixtures for throttling, 410 subdivision, resume, deduplication, redaction, and incomplete collections.

## AI boundary

AI can summarize structured facts, suggest hypotheses, propose remediation language, and review code. It must not silently promote a hypothesis into a fact or treat a name-based signal as a proven security control.

Production evidence must not be sent to third-party AI or security services unless separately approved by the organization. The repository should contain only code, schemas, documentation, and fictional/lab fixtures.
