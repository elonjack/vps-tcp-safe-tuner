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
foreach ($lossRecoveryKey in @('tcp_sack', 'tcp_dsack', 'tcp_timestamps', 'tcp_no_metrics_save')) {
    if ($content -notmatch "add_setting net\.ipv4\.$lossRecoveryKey") { throw "Missing managed loss-recovery baseline: $lossRecoveryKey" }
}
if ($content -notmatch 'add_setting net\.core\.netdev_budget 600') { throw 'Missing bounded softnet processing budget.' }
if ($content -match 'add_setting net\.core\.(rmem_default|wmem_default)') { throw 'TCP defaults must not alter global socket defaults.' }
if ($content -notmatch 'restore_legacy_core_defaults') { throw 'Missing v3.6.0 global default migration.' }
if ($content -notmatch 'RETRANS_PER_GIB_HARD_LIMIT') { throw 'Missing transfer-normalized retransmission guard.' }
if ($content -notmatch 'MAX_RATE_SPREAD_PERCENT') { throw 'Missing multi-round stability guard.' }
if ($content -notmatch 'inliers >= required') { throw 'Missing majority-cluster handling for five-round noisy samples.' }
if ($content -notmatch 'NOISY_LINK=0') { throw 'Missing noisy-link classification.' }
if ($content -notmatch 'apply_managed_fq') { throw 'Missing directly managed active FQ application.' }
if ($content -notmatch 'tune --bandwidth N') { throw 'Missing benchmark-independent one-click tuning path.' }
if ($content -match "yellow '\[业务目标 RTT") { throw 'The beginner menu must not require a misleading point RTT sample.' }
if ($content -notmatch 'candidate_retrans_is_acceptable') { throw 'Missing baseline-relative buffer candidate retransmission guard.' }
if ($content -notmatch 'command\+=\(-R\)') { throw 'Missing iperf3 reverse-direction measurement.' }
if ($content -notmatch 'qdisc_candidate_is_better') { throw 'Missing measured FQ candidate selection.' }
if ($content -notmatch 'restore_managed_qdisc_tune') { throw 'Missing managed active-qdisc rollback.' }
if ($content -notmatch 'normalize_qdisc_spec') { throw 'Missing tc display-to-input qdisc normalization.' }
if ($content -notmatch 'abort_after_qdisc_restore_failure') { throw 'Missing sysctl fallback after qdisc restore failure.' }
if ($content -notmatch 'MEASURE_STAGE_TRANSFER_MIB') { throw 'Missing runtime traffic-volume guard.' }
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
if ($content -notmatch 'find_sysctl_conflicts') { throw 'Missing persistent sysctl conflict detection.' }
if ($content -notmatch 'verify_built_settings') { throw 'Missing live sysctl read-back verification.' }
if ($content -notmatch 'CONFIG_TRANSACTION_FILE') { throw 'Missing managed-config transaction backup.' }
if ($installContent -notmatch "readonly VERSION='6\.3\.0'") { throw 'Installer version is stale.' }
if ($installContent -match "EXPECTED_SHA256='TO_BE_REPLACED'") { throw 'Installer checksum placeholder was not replaced.' }
if ($installContent -notmatch '--local') { throw 'Installer needs an offline/local verified path.' }
$expectedMatch = [regex]::Match($installContent, "EXPECTED_SHA256='([0-9a-f]{64})'")
if (-not $expectedMatch.Success) { throw 'Installer checksum is malformed.' }
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $scriptPath).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedMatch.Groups[1].Value) { throw 'Installer checksum does not match vps-tcp-tune.sh.' }

Write-Host 'Static security checks passed.'
