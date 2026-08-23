# Contributing

Contributions are welcome when they preserve the safety model.

1. Use fictional fixtures. Never submit tenant exports or personal identifiers.
2. Keep provider adapters read-only by default.
3. Add Pester coverage for new behavior and failure paths.
4. Document permissions and unsupported evidence explicitly.
5. Do not introduce one-line remote execution such as `irm ... | iex`.

Run tests with:

```powershell
Invoke-Pester ./tests -CI
```
