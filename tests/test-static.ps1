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

Write-Host 'Static security checks passed.'
