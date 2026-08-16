$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\vps-tcp-tune.sh'
$content = Get-Content -Raw -LiteralPath $scriptPath

if ($content -match '(?m)^\s*(curl|wget)\b') { throw 'Remote download is not allowed in the main script.' }
if ($content -match '(?m)^\s*(apt-get|apt)\s+update\b') { throw 'Automatic package-index refresh is not allowed.' }
if ($content -match '(?m)\brm\s+-rf\b') { throw 'Recursive forced deletion is not allowed.' }
if ($content -match '\beval\b|\bsource\b|\bexec\s+.*<(curl|wget)') { throw 'Dynamic remote execution is not allowed.' }
if ($content -notmatch 'baseline\.tsv') { throw 'Missing sysctl baseline snapshot.' }
if ($content -notmatch 'qdisc\.tsv') { throw 'Missing qdisc state tracking.' }
if ($content -notmatch 'ENABLE_SHAPING=0') { throw 'Shaping must default to disabled.' }
if ($content -notmatch 'qdisc_is_restorable') { throw 'Root qdisc must be checked for restorability.' }
if ($content -notmatch 'restore_snapshot_values') { throw 'Missing rollback implementation.' }
if ($content -notmatch 'ensure_bbr') { throw 'Missing automatic BBR loading.' }
if ($content -notmatch 'BBR_MODULE_MARKER') { throw 'Missing managed BBR persistence marker.' }
if ($content -match 'awk\s+-v\s+index=') { throw 'Do not shadow the awk index() builtin.' }
if ($content -notmatch "AUTO_TARGET_RTT_MS='150'") { throw 'Missing cross-region BDP target RTT.' }
if ($content -match 'RTT_MS=\$MEASURE_RTT') { throw 'Do not use a near measurement peer RTT as the BDP target RTT.' }
if ($content -notmatch 'calculate_initial_rmem') { throw 'Missing role-aware TCP receive buffer calculation.' }
if ($content -notmatch 'calculate_initial_wmem') { throw 'Missing role-aware TCP send buffer calculation.' }
if ($content -match 'add_setting net\.core\.(rmem_default|wmem_default)') { throw 'TCP defaults must not alter global socket defaults.' }
if ($content -notmatch 'restore_legacy_core_defaults') { throw 'Missing v3.6.0 global default migration.' }
if ($content -notmatch 'baseline_retrans \* 2 \+ 10') { throw 'Missing relative retransmission rollback guard.' }

Write-Host 'Static security checks passed.'
