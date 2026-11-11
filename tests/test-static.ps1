$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\vps-tcp-tune.sh'
$content = Get-Content -Raw -LiteralPath $scriptPath
$installPath = Join-Path $PSScriptRoot '..\install.sh'
$installContent = Get-Content -Raw -LiteralPath $installPath

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
if ($content -notmatch 'transaction\.tsv') { throw 'Missing per-run transaction snapshot.' }
if ($content -notmatch 'restore_transaction_values') { throw 'Missing per-run transaction restore.' }
if ($content -notmatch 'run_measure_iperf') { throw 'Missing same-peer iperf3 port fallback.' }
if ($content -notmatch 'active_htb_rate') { throw 'Missing active HTB rate detection.' }
if ($content -match 'telemetry|STATS_URL|spacevps\.cc') { throw 'Main script must not contain telemetry or author-controlled tracking endpoints.' }
if ($content -notmatch 'ALLOW_PUBLIC_PEERS=0') { throw 'Public peers must require explicit opt-in.' }
if ($content -notmatch 'ALLOW_HIGH_TRAFFIC=0') { throw 'High traffic must require explicit opt-in.' }
if ($content -notmatch 'SHAPE_SCRIPT_MARKER') { throw 'Persistent shaping script needs an ownership marker.' }
if ($content -notmatch 'SHAPE_UNIT_MARKER') { throw 'Persistent shaping unit needs an ownership marker.' }
if ($content -notmatch 'validate_iface') { throw 'Interface names must be validated before persistence.' }
if ($content -notmatch '部分 sysctl 恢复失败；配置和快照均已保留') { throw 'Rollback must retain evidence after partial restore failure.' }
if ($installContent -notmatch "readonly VERSION='4\.0\.0'") { throw 'Installer version is stale.' }
if ($installContent -match "EXPECTED_SHA256='TO_BE_REPLACED'") { throw 'Installer checksum placeholder was not replaced.' }
if ($installContent -notmatch '--local') { throw 'Installer needs an offline/local verified path.' }
$expectedMatch = [regex]::Match($installContent, "EXPECTED_SHA256='([0-9a-f]{64})'")
if (-not $expectedMatch.Success) { throw 'Installer checksum is malformed.' }
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $scriptPath).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedMatch.Groups[1].Value) { throw 'Installer checksum does not match vps-tcp-tune.sh.' }

Write-Host 'Static security checks passed.'
