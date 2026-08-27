# AGENTS.md

## Purpose

ChangePack365 is an evidence-first Microsoft 365 operations toolkit. Agents must optimize for safety, traceability, reproducibility, and factual reporting. Do not turn it into an autonomous remediation or posture-scanning product.

## Safety boundary

- Default to read-only behavior.
- Never introduce Microsoft 365 writes as an implicit side effect.
- Any write path must be explicitly separated from evidence collection and require operator approval.
- Do not add automatic remediation.
- Do not weaken tenant/account fingerprint checks.
- Do not suppress unexpected or forbidden deltas.
- Do not upload tenant evidence, credentials, identifiers, logs, or customer data to third-party services.
- Tests and examples must use fictional or lab data only.

## Evidence rules

- Separate FACT, INFERENCE, and HYPOTHESIS.
- Preserve source timestamps and collection context.
- Hash evidence artifacts with SHA256 where practical.
- Prefer append-only evidence and deterministic outputs.
- A missing relationship is not proof of absence. Example: no Intune device linked by UPN does not mean the user is unmanaged.
- Never claim password-only authentication without authentication evidence that supports it.
- Never infer security effect from a group or policy name alone; verify actual assignments and controls.
- Treat incomplete collection as incomplete, not successful.

## Microsoft Graph collection

- GET is the default method.
- POST to `/$batch` is acceptable only when every subrequest is GET and the caller explicitly chooses that mode.
- Handle pagination, throttling, transient errors, and expired skip tokens explicitly.
- For large collections, prefer time slicing, checkpointing, resume, deduplication, and completeness metrics.
- Log failed objects separately; never silently drop them.
- Preserve the original query window and collection timestamp.

## PowerShell engineering

- Target PowerShell 7.2+ unless a compatibility requirement is documented.
- Use `Set-StrictMode` and terminating errors where appropriate.
- Avoid quadratic loops over large collections; build hashtable indexes for joins.
- Prefer `System.Collections.Generic.List[object]` for large append-heavy collections.
- Keep provider adapters independently reviewable.
- Functions should be small, testable, and explicit about read/write behavior.
- Add Pester tests for safety boundaries, deterministic output, redaction, pagination/retry, and failure handling.

## Privacy and public artifacts

- Internal evidence may retain fidelity only when explicitly intended for internal use.
- Public/shared artifacts must pseudonymize or remove UPNs, GUIDs, IPv4 addresses, tenant names, customer names, and other identifying data as required by the case contract.
- Do not commit production evidence, tenant exports, secrets, tokens, or real customer identifiers to Git.
- `.gitignore` must cover generated evidence directories and local secrets.

## Findings and summaries

Every security or operational finding should include, when applicable:

- finding ID
- title
- severity or priority
- confidence
- affected population
- evidence references
- root cause
- limitation/unknowns
- recommendation
- owner/status when supplied by the operator

Generated summaries must be fact-bound. Do not invent business impact, remediation status, user intent, authentication method, or certainty.

## Change review checklist

Before proposing or approving code changes, verify:

1. Does this change preserve read-only-by-default behavior?
2. Can it modify Microsoft 365, Entra, Intune, Exchange, or Graph objects unexpectedly?
3. Are tenant/account fingerprints still enforced where relevant?
4. Are errors, pagination, retries, and incomplete results visible?
5. Are outputs deterministic and auditable?
6. Could sensitive tenant data reach GitHub, logs, CI, or third parties?
7. Are new behaviors covered by tests?
8. Does documentation clearly state the security boundary?

## Agent behavior

- Prefer minimal, reviewable diffs.
- Explain blast radius for any proposed write capability.
- Do not merge or enable auto-merge unless the user explicitly requests it.
- Do not modify production tenant configuration.
- When uncertain, preserve evidence and stop rather than guessing.
