# Changelog

## 0.2.0 - 2026-09-03

- Added resilient time-sliced Microsoft Graph collection with pagination, deduplication, checkpoints, and transient-error retries.
- Added deterministic query fingerprints to isolate checkpoint sets.
- Added normalized Graph evidence records with portable artifact registration.
- Added offline verification of internal case packages, including safe ZIP extraction, exact inventory, hashes, and ledger validation.
- Added detached CMS/PKCS#7 manifest signatures with optional independent signer-thumbprint verification.
- Added explicit Valid, Invalid, Incomplete, and Unsupported verification results.
- Expanded cross-platform Pester coverage to 47 tests.

## 0.1.0 - 2026-08-23

- Introduced provider-neutral change cases and contracts.
- Added tenant/account context fingerprints.
- Added expected, unexpected, and forbidden delta classification.
- Added tamper-evident hash-chained ledgers.
- Added internal and pseudonymized public evidence bundles.
- Added fictional demo data and Pester tests.
