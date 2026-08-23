function Export-CP365HtmlReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CasePath, [string]$OutputPath)

    $context = Get-CP365CaseContext -CasePath $CasePath
    $diffFile = Get-ChildItem -LiteralPath (Join-Path $context.Root 'diff') -Filter 'diff-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $diffFile) { throw 'No snapshot comparison was found. Run Compare-CP365Snapshot first.' }

    $changes = @(Get-Content -LiteralPath $diffFile.FullName -Raw | ConvertFrom-Json -Depth 100)
    $ledger = @(Get-Content -LiteralPath $context.LedgerPath | Where-Object { $_ } | ConvertFrom-Json -Depth 100)
    $encode = { param([AllowNull()][object]$Value) [System.Net.WebUtility]::HtmlEncode([string]$Value) }
    $counts = @{
        Expected = @($changes | Where-Object classification -eq 'Expected').Count
        Unexpected = @($changes | Where-Object classification -eq 'Unexpected').Count
        Forbidden = @($changes | Where-Object classification -eq 'Forbidden').Count
    }
    $decision = if ($counts.Forbidden) { 'STOP' } elseif ($counts.Unexpected) { 'REVIEW' } else { 'ALIGNED' }
    $decisionClass = $decision.ToLowerInvariant()

    $deltaRows = foreach ($change in $changes) {
        $classification = $encode.Invoke([string]$change.classification)
        "<tr><td><span class='pill $($classification.ToLowerInvariant())'>$classification</span></td><td><code>$($encode.Invoke([string]$change.path))</code></td><td>$($encode.Invoke([string]$change.operation))</td><td><code>$($encode.Invoke([string]$change.before))</code></td><td><code>$($encode.Invoke([string]$change.after))</code></td></tr>"
    }
    $timeline = foreach ($entry in $ledger) {
        "<li><span>$($encode.Invoke([string]$entry.eventType))</span><small>#$($entry.sequence) · $($encode.Invoke([string]$entry.timestampUtc))</small></li>"
    }
    $reportPath = if ($OutputPath) { $OutputPath } else { Join-Path $context.Root 'public/change-report.html' }
    New-Item -ItemType Directory -Path (Split-Path -Parent $reportPath) -Force | Out-Null

    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ChangePack365 · $($encode.Invoke([string]$context.Contract.caseId))</title><style>
:root{color-scheme:dark;--bg:#07111f;--panel:#0d1c2f;--line:#203552;--text:#eef6ff;--muted:#8fa8c3;--cyan:#35d9ff;--green:#4ade80;--amber:#fbbf24;--red:#fb7185}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 80% 0,#12345a 0,transparent 35%),var(--bg);color:var(--text);font:15px/1.5 Inter,Segoe UI,sans-serif}.wrap{max-width:1180px;margin:auto;padding:48px 24px}header{display:flex;justify-content:space-between;gap:24px;align-items:flex-start;margin-bottom:28px}.eyebrow{color:var(--cyan);font-weight:700;letter-spacing:.16em;text-transform:uppercase}h1{font-size:clamp(32px,6vw,64px);line-height:1;margin:10px 0}.fingerprint{font:700 18px Consolas,monospace;border:1px solid var(--cyan);padding:12px 16px;border-radius:12px;color:var(--cyan)}.decision{padding:12px 18px;border-radius:999px;font-weight:800;letter-spacing:.12em}.review{background:#3d2d08;color:var(--amber)}.stop{background:#421522;color:var(--red)}.aligned{background:#0d3824;color:var(--green)}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}.card,.panel{background:linear-gradient(145deg,#10233a,#0a1728);border:1px solid var(--line);border-radius:18px;padding:22px;box-shadow:0 16px 50px #0004}.metric{font-size:42px;font-weight:800}.muted,small{color:var(--muted)}.panel{margin-top:18px;overflow:auto}table{width:100%;border-collapse:collapse;min-width:780px}th,td{text-align:left;padding:13px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.1em}code{color:#c9e8ff}.pill{display:inline-block;padding:3px 9px;border-radius:999px;font-weight:700;font-size:12px}.expected{background:#123b2a;color:var(--green)}.unexpected{background:#3d2d08;color:var(--amber)}.forbidden{background:#421522;color:var(--red)}ol{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;padding:0;list-style:none}li{border-left:3px solid var(--cyan);padding:8px 12px;background:#07111f}li span,li small{display:block}footer{margin-top:24px;color:var(--muted)}@media(max-width:700px){header{display:block}.fingerprint{margin-top:18px}.grid{grid-template-columns:1fr}}
</style></head><body><main class="wrap"><header><div><div class="eyebrow">ChangePack365 evidence</div><h1>$($encode.Invoke([string]$context.Contract.title))</h1><div class="muted">$($encode.Invoke([string]$context.Contract.target.displayName)) · $($encode.Invoke([string]$context.Contract.caseId))</div></div><div><div class="fingerprint">$($encode.Invoke([string]$context.Contract.target.fingerprint))</div><p class="decision $decisionClass">$decision</p></div></header>
<section class="grid"><article class="card"><div class="muted">Expected</div><div class="metric">$($counts.Expected)</div></article><article class="card"><div class="muted">Unexpected</div><div class="metric">$($counts.Unexpected)</div></article><article class="card"><div class="muted">Forbidden</div><div class="metric">$($counts.Forbidden)</div></article></section>
<section class="panel"><h2>Evidence timeline</h2><ol>$($timeline -join '')</ol></section>
<section class="panel"><h2>Observed deltas</h2><table><thead><tr><th>Class</th><th>Path</th><th>Operation</th><th>Before</th><th>After</th></tr></thead><tbody>$($deltaRows -join '')</tbody></table></section>
<footer>Generated from structured evidence. No business impact was inferred. Ledger head: <code>$($encode.Invoke([string]$ledger[-1].entryHash))</code></footer></main></body></html>
"@
    $html | Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-CP365LedgerEvent -CasePath $context.Root -EventType 'HtmlReportCreated' -Payload @{ file = Split-Path -Leaf $reportPath; sha256 = Get-CP365Hash -Path $reportPath; decision = $decision } | Out-Null
    Get-Item -LiteralPath $reportPath
}
