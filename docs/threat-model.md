# Threat model

## Assets

- Tenant identity and operator context
- Before/after snapshots
- Change intent and approval metadata
- Evidence ledger and exported bundles

## Threats addressed in the MVP

| Threat | Control |
|---|---|
| Operator connects to the wrong tenant | Context fingerprint and exact confirmation phrase |
| A change affects an undeclared property | Unexpected delta classification |
| A protected property changes | Forbidden delta classification |
| Evidence is edited after collection | SHA-256 manifest and hash-chained ledger |
| A public demo leaks tenant identifiers | Case-scoped deterministic pseudonymization |
| A tool claims success with incomplete evidence | No green score; unresolved deltas remain explicit |

## Threats not yet addressed

- Compromise of the host running ChangePack365
- Malicious provider adapters
- Cryptographic non-repudiation by an external timestamp authority
- Screenshots and binary formats that contain unredacted text
- Authorization and approval outside the structured contract
