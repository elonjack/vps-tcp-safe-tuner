$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\vps-tcp-tune.sh'
$content = Get-Content -Raw -LiteralPath $scriptPath

if ($content -match '(?m)^\s*(curl|wget)\b') { throw '脚本不得下载远程代码。' }
if ($content -match '(?m)^\s*(apt|apt-get|dnf|yum|apk)\b') { throw '脚本不得自动安装软件包。' }
if ($content -match '(?m)^\s*(iptables|nft|ufw|firewall-cmd)\b') { throw '脚本不得修改防火墙。' }
if ($content -match '(?m)^\s*(tc)\s+(qdisc|class)\s+(add|change|replace|del)\b') { throw '脚本不得修改活动 qdisc 或 tc 限速。' }
if ($content -match '\beval\b|\bsource\b|\bexec\s+.*<(curl|wget)') { throw '脚本不得执行动态远程内容。' }
if ($content -notmatch 'baseline\.tsv') { throw '脚本必须含可回滚快照。' }

Write-Host '静态安全检查通过。'
