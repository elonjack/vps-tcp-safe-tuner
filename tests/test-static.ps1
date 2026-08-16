$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\vps-tcp-tune.sh'
$content = Get-Content -Raw -LiteralPath $scriptPath

if ($content -match '(?m)^\s*(curl|wget)\b') { throw '脚本不得下载或执行远程内容。' }
if ($content -match '(?m)^\s*(apt-get|apt)\s+update\b') { throw '脚本不得自动刷新系统软件源。' }
if ($content -match '(?m)\brm\s+-rf\b') { throw '脚本不得使用递归强制删除。' }
if ($content -match '\beval\b|\bsource\b|\bexec\s+.*<(curl|wget)') { throw '脚本不得执行动态远程内容。' }
if ($content -notmatch 'baseline\.tsv') { throw '脚本必须含 sysctl 精确快照。' }
if ($content -notmatch 'qdisc\.tsv') { throw '脚本必须记录整形状态。' }
if ($content -notmatch 'ENABLE_SHAPING=0') { throw '整形必须默认关闭。' }
if ($content -notmatch 'qdisc_is_restorable') { throw '整形前必须验证可恢复的根队列。' }
if ($content -notmatch 'restore_snapshot_values') { throw '脚本必须具备回滚实现。' }

Write-Host '静态安全检查通过。'
