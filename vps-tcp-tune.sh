#!/usr/bin/env bash
# vps-tcp-safe-tuner: 自适应、可测量、可回滚的 Linux VPS TCP 调优工具。
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly VERSION='6.5.1'
readonly STATE_DIR='/var/lib/vps-tcp-safe-tuner'
readonly SNAPSHOT_FILE="$STATE_DIR/baseline.tsv"
readonly TRANSACTION_FILE="$STATE_DIR/transaction.tsv"
readonly CONFIG_TRANSACTION_FILE="$STATE_DIR/config.before"
readonly CONFIG_TRANSACTION_ABSENT="$STATE_DIR/config.before.absent"
readonly FACTS_FILE="$STATE_DIR/facts.tsv"
readonly CONFIG_FILE='/etc/sysctl.d/99-vps-tcp-safe-tuner.conf'
readonly LOCK_FILE='/run/lock/vps-tcp-safe-tuner.lock'
readonly SHAPE_SCRIPT='/usr/local/sbin/vps-tcp-safe-tuner-qdisc'
readonly SHAPE_UNIT='/etc/systemd/system/vps-tcp-safe-tuner-qdisc.service'
readonly SHAPE_STATE="$STATE_DIR/qdisc.tsv"
readonly QDISC_TUNE_STATE="$STATE_DIR/qdisc-tune.tsv"
readonly ROUTE_STATE="$STATE_DIR/route-window.tsv"
readonly RUNTIME_SCRIPT='/usr/local/sbin/vps-tcp-safe-tuner-runtime'
readonly RUNTIME_UNIT='/etc/systemd/system/vps-tcp-safe-tuner-runtime.service'
readonly RUNTIME_TIMER='/etc/systemd/system/vps-tcp-safe-tuner-runtime.timer'
readonly RUNTIME_MARKER='# Managed by vps-tcp-safe-tuner: runtime recovery.'
readonly BBR_MODULE_FILE='/etc/modules-load.d/vps-tcp-safe-tuner-bbr.conf'
readonly REPORT_DIR='/var/log/vps-tcp-safe-tuner'
readonly MARKER='# Managed by vps-tcp-safe-tuner. Remove only with vps-tcp-tune rollback.'
readonly BBR_MODULE_MARKER='# Managed by vps-tcp-safe-tuner: load BBR at boot.'
readonly SHAPE_SCRIPT_MARKER='# Managed by vps-tcp-safe-tuner: egress shaper helper.'
readonly SHAPE_UNIT_MARKER='# Managed by vps-tcp-safe-tuner: egress shaper unit.'
readonly AUTO_TARGET_RTT_MS='150'
readonly AUTO_BUFFER_HEADROOM_PERCENT='150'
readonly RETRANS_PER_GIB_HARD_LIMIT='2000'
readonly RETRANS_PER_GIB_MARGIN='500'
readonly RETRANS_RELATIVE_MULTIPLIER='3'

COMMAND='menu'; ROLE='general'; PEER=''; PEER_PORT='5201'; BANDWIDTH_MBIT=''; BUFFER_BANDWIDTH_MBIT=''; RTT_MS=''
DURATION='12'; WORKERS='4'; ROUNDS='3'; POLICER_ROUNDS='3'; PEER_MAX_RTT='120'; MAX_TEST_GIB='50'; MAX_RATE_SPREAD_PERCENT='40'; BUFFER_MULTIPLIER_OVERRIDE=''; SHAPE_RATE=''; ENABLE_SHAPING=0; BUFFER_SEARCH=0; QDISC_EXPERIMENT=0; DRY_RUN=0; ASSUME_YES=0; NO_INSTALL=0; KEEP_ON_REGRESSION=0; ALLOW_PUBLIC_PEERS=0; ALLOW_HIGH_TRAFFIC=0; BIDIRECTIONAL=1
ALLOW_SYSCTL_CONFLICTS=0
SYSCTL_CONFLICT_COUNT=0; SYSCTL_BLOCKING_CONFLICT_COUNT=0
TUNING_APPLIED=0; DEFER_PERSIST=0; BBR_MODULE_CONFIG_CREATED=0
APPLIED_CHANGED_COUNT=0; APPLIED_UNCHANGED_COUNT=0; WIZARD_MODE=0; MENU_MODE=0
QDISC_SELECTED_FQ=0; QDISC_CHANGED=0; QDISC_ORIGINAL_IFACE=''; QDISC_ORIGINAL_KIND=''; QDISC_ORIGINAL_SPEC=''; QDISC_BACKUP_FILE=''
NOISY_LINK=0
INITCWND=32
RECOMMENDED_SHAPE_RATE=''

# 第三方公开 iperf3 节点。自动模式会按 RTT 排序、依次做短测试；用户也可用 --peer 覆盖。
# 节点可用性会变化，因此自动选择失败时会给出明确提示，不会伪造测量结果。
readonly PUBLIC_PEERS='
speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb
speedtest.sin1.sg.leaseweb.net|新加坡|Leaseweb
sgp.proof.ovh.net|新加坡|OVH
speedtest.syd12.au.leaseweb.net|悉尼|Leaseweb
speedtest.tyo11.jp.leaseweb.net|东京|Leaseweb
speedtest.fra1.de.leaseweb.net|法兰克福|Leaseweb
speedtest.ams2.nl.leaseweb.net|阿姆斯特丹|Leaseweb
ams.speedtest.clouvider.net|阿姆斯特丹|Clouvider
speedtest.lon12.uk.leaseweb.net|伦敦|Leaseweb
lon.speedtest.clouvider.net|伦敦|Clouvider
speedtest.lax12.us.leaseweb.net|洛杉矶|Leaseweb
speedtest.sfo12.us.leaseweb.net|旧金山|Leaseweb
speedtest.sea11.us.leaseweb.net|西雅图|Leaseweb
speedtest.dal13.us.leaseweb.net|达拉斯|Leaseweb
speedtest.chi11.us.leaseweb.net|芝加哥|Leaseweb
speedtest.nyc1.us.leaseweb.net|纽约|Leaseweb
speedtest.mia11.us.leaseweb.net|迈阿密|Leaseweb
speedtest.mtl2.ca.leaseweb.net|蒙特利尔|Leaseweb'
readonly -a IPERF_PORTS=(5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200)
readonly -a MANAGED_SYSCTL_KEYS=(
  net.ipv4.tcp_congestion_control net.core.default_qdisc
  net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_mem
  net.ipv4.tcp_window_scaling net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_sack net.ipv4.tcp_dsack net.ipv4.tcp_timestamps net.ipv4.tcp_no_metrics_save
  net.ipv4.tcp_early_retrans net.ipv4.tcp_recovery net.ipv4.tcp_reordering net.ipv4.tcp_fastopen
  net.ipv4.tcp_slow_start_after_idle net.core.netdev_max_backlog net.core.netdev_budget net.core.somaxconn
  net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range
)

yellow() { if [[ -t 1 ]]; then printf '\033[1;33m%s\033[0m' "$*"; else printf '%s' "$*"; fi; }
say() { yellow "[信息] $*"; printf '\n'; }
warn() { yellow "[警告] $*" >&2; printf '\n' >&2; }
fail() { yellow "[错误] $*" >&2; printf '\n' >&2; exit 1; }
ok() { yellow "[完成] $*"; printf '\n'; }
line() { yellow '============================================================'; printf '\n'; }

usage() {
  yellow "$(cat <<'EOF'
vps-tcp-tune - 自适应 Linux VPS TCP 调优工具

命令：
  menu                         中文交互菜单（默认）
  audit                        只检测内核、虚拟化、网卡和 TCP 能力
  measure [--peer 主机]        多轮吞吐、重传、RTT 基线测试；省略对端则自动选择公共节点
  wizard --bandwidth N          五阶段一键调优：基础配置、路径检测、拐点扫描、整形、验证
  tune --bandwidth N [--rtt N] 快速基础调优：直接应用 BBR、FQ 和自适应缓冲区
  auto --peer 主机             实测后自动推导 BDP 并应用、复测调优
  deep --peer 主机             深度实验：缓冲区倍率 + 活动 FQ 队列双向 A/B 择优
  apply --bandwidth N --rtt N  按已知带宽/RTT 应用调优
  shape --shape-rate N         应用 HTB + FQ 出向整形（须先明确确认）
  unshape                      移除本工具的整形并恢复可恢复的根队列类型
  verify --peer 主机           输出调优后的实测结果
  status                       查看当前配置、快照与整形状态
  rollback                     还原本工具管理的 sysctl 与整形

通用选项：
  --peer HOST          iperf3 对端域名或 IPv4 地址；省略时自动选择公共节点
  --port PORT          对端端口，默认 5201
  --role general|proxy|server  用途影响队列和端口范围策略，默认 general
  --bandwidth MBIT     标称或实测出口带宽（Mbit/s）
  --rtt MS             业务目标方向的典型 RTT（毫秒）；auto 默认 150
  --duration SEC       单次 iperf3 测试时长，默认 12 秒
  --workers N          iperf3 并发流数，默认 4
  --rounds N           每个阶段的独立测试轮数，默认 3，范围 1 到 5
  --policer-rounds N   每个限速器候选的测试轮数，默认 3，范围 2 到 5
  --peer-max-rtt MS    自动选择公共对端的最大 RTT，默认 120 ms
  --allow-public-peers 明确允许探测并测速内置第三方公共节点；非交互自动选择时必需
  --max-test-gib N     单个阶段允许的估算流量上限，默认 50 GiB
  --allow-high-traffic 明确允许超过流量上限；--yes 不会代替此授权
  --max-rate-spread N  多轮吞吐最大波动百分比，默认 40；超出则拒绝据此调优
  --forward-only       只测试 VPS 出站；默认同时测试出站和入站
  --enable-shaping     auto 成功后，允许进入限速器扫描和整形候选流程
  --search-buffers     对 1×、2×、3× BDP 缓冲区进行 A/B 测试并自动保留最佳候选
  --experiment-qdisc   临时比较原活动 qdisc 与 FQ；只在双向结果更好时保留 FQ
  --shape-rate MBIT    shape 使用的目标速率
  --no-install         不允许脚本安装 iperf3
  --keep-on-regression 即使复测明显退化，也不自动回滚（默认会回滚）
  --allow-sysctl-conflicts 允许与其它 sysctl 文件管理相同参数（默认拒绝）
  --dry-run            仅显示动作，不写入系统
  --yes                非交互确认（整形仍要求 --enable-shaping）

示例：
  sudo bash vps-tcp-tune.sh audit
  sudo bash vps-tcp-tune.sh tune --bandwidth 1000 --rtt 180 --role proxy
  sudo bash vps-tcp-tune.sh auto --peer 203.0.113.10 --role proxy
  sudo bash vps-tcp-tune.sh auto --rounds 3 --role proxy
  sudo bash vps-tcp-tune.sh auto --rtt 180 --role proxy
  sudo bash vps-tcp-tune.sh deep --peer 203.0.113.10 --role proxy
  sudo bash vps-tcp-tune.sh apply --bandwidth 1000 --rtt 150 --role proxy
  sudo bash vps-tcp-tune.sh shape --shape-rate 950 --enable-shaping
  sudo bash vps-tcp-tune.sh rollback
EOF
)"
  printf '\n'
}

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail '需要 root 权限，请使用 sudo 执行。'; }
require_linux() { [[ $(uname -s) == Linux ]] || fail '仅支持 Linux。'; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "缺少必要命令：$1"; }
is_positive_integer() { [[ ${1:-} =~ ^[1-9][0-9]*$ ]]; }
is_safe_iface() { [[ ${1:-} =~ ^[A-Za-z0-9_.-]{1,15}$ ]]; }
validate_iface() { is_safe_iface "$1" || fail "网卡名不安全或无效：${1:-<空>}"; }

confirm() {
  local message=$1 answer
  (( ASSUME_YES )) && { say "$message（已由 --yes 确认）"; return 0; }
  [[ -t 0 ]] || fail '非交互运行需要 --yes；整形还需要 --enable-shaping。'
  yellow "[确认] $message [y/N] "
  read -r answer
  [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
}

confirm_default_yes() {
  local message=$1 answer
  (( ASSUME_YES )) && { say "$message（已由 --yes 确认）"; return 0; }
  [[ -t 0 || $MENU_MODE == 1 ]] || fail '非交互运行需要 --yes。'
  yellow "[确认] $message [Y/n] "
  read -r answer
  [[ -z $answer || $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
}

confirm_high_traffic() {
  local message=$1 answer
  yellow "[确认] $message [y/N] "
  read -r answer
  [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
}

lock() {
  require_command flock
  install -d -m 755 "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || fail '已有本工具实例正在运行；已退出以避免并发修改。'
}

sysctl_value() { sysctl -n "$1" 2>/dev/null || true; }
sysctl_exists() {
  local names
  names=$(sysctl -aN 2>/dev/null || true)
  [[ $'\n'$names$'\n' == *$'\n'"$1"$'\n'* ]]
}
normalize_sysctl_value() { awk '{$1=$1; print}' <<<"$1"; }

# 列出会与本工具争用同一参数的持久化配置。这里只报告，不修改第三方文件。
sysctl_config_files() {
  local directory path resolved
  local -A seen=()
  if [[ -f /etc/sysctl.conf ]]; then
    resolved=$(readlink -f -- /etc/sysctl.conf 2>/dev/null || printf '%s' /etc/sysctl.conf)
    seen[$resolved]=1
    printf '%s\n' /etc/sysctl.conf
  fi
  for directory in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d; do
    [[ -d $directory ]] || continue
    while IFS= read -r path; do
      resolved=$(readlink -f -- "$path" 2>/dev/null || printf '%s' "$path")
      [[ -n ${seen[$resolved]:-} ]] && continue
      seen[$resolved]=1
      printf '%s\n' "$path"
    done < <(find "$directory" -maxdepth 1 \( -type f -o -type l \) -name '*.conf' -print 2>/dev/null | sort)
  done
}

sysctl_key_is_managed() {
  local candidate=$1 managed_key
  shift
  for managed_key in "$@"; do [[ $candidate == "$managed_key" ]] && return 0; done
  return 1
}

find_sysctl_conflicts() {
  local file raw line key value
  local -a wanted_keys=("$@") files=()
  ((${#wanted_keys[@]})) || return 0
  if [[ -n ${SYSCTL_CONFIG_FILES_OVERRIDE:-} ]]; then
    while IFS= read -r file; do [[ -n $file ]] && files+=("$file"); done <<<"$SYSCTL_CONFIG_FILES_OVERRIDE"
  else
    while IFS= read -r file; do files+=("$file"); done < <(sysctl_config_files)
  fi
  for file in "${files[@]}"; do
    [[ $file == "$CONFIG_FILE" || ! -r $file ]] && continue
    while IFS= read -r raw || [[ -n $raw ]]; do
      line=${raw%%#*}; line=${line%%;*}
      [[ $line == *=* ]] || continue
      key=${line%%=*}; value=${line#*=}
      key=$(normalize_sysctl_value "$key"); key=${key#-}; key=${key//\//.}
      sysctl_key_is_managed "$key" "${wanted_keys[@]}" || continue
      value=$(normalize_sysctl_value "$value")
      printf '%s\t%s\t%s\n' "$file" "$key" "$value"
    done <"$file"
  done
}

report_sysctl_conflicts() {
  local conflicts file key value basename managed_basename blocking=0
  SYSCTL_CONFLICT_COUNT=0; SYSCTL_BLOCKING_CONFLICT_COUNT=0
  conflicts=$(find_sysctl_conflicts "$@")
  [[ -n $conflicts ]] || return 0
  managed_basename=${CONFIG_FILE##*/}
  warn '检测到其它持久化 sysctl 文件也在管理本次参数：'
  while IFS=$'\t' read -r file key value; do
    SYSCTL_CONFLICT_COUNT=$(( SYSCTL_CONFLICT_COUNT + 1 ))
    basename=${file##*/}
    # 同名文件由 /etc 版本优先；更早的文件会被本工具 99-vps... 明确覆盖。
    # /etc/sysctl.conf 及文件名排序更晚的配置可能在启动时重新覆盖本工具。
    if [[ $file == /etc/sysctl.conf || $basename > "$managed_basename" ]]; then
      warn "  [阻断] $file: $key = $value"
      SYSCTL_BLOCKING_CONFLICT_COUNT=$(( SYSCTL_BLOCKING_CONFLICT_COUNT + 1 ))
      blocking=1
    else
      warn "  [较早/被覆盖] $file: $key = $value"
    fi
  done <<<"$conflicts"
  (( blocking )) || { warn '这些配置的文件名排序早于本工具；本工具会覆盖相同键，但卸载后它们可能重新生效。'; return 0; }
  if (( ALLOW_SYSCTL_CONFLICTS )); then
    warn '阻断冲突已由 --allow-sysctl-conflicts 明确放行；应用后仍会逐项加载并读回验证。'
    return 0
  fi
  warn '存在会在本工具之后加载的配置；为避免重启后改变结果，默认拒绝继续。请先合并/停用阻断文件，或审阅后显式使用 --allow-sysctl-conflicts。'
  return 1
}

kernel_supports_bbr() { [[ " $(sysctl_value net.ipv4.tcp_available_congestion_control) " == *' bbr '* ]]; }
write_bbr_module_config() {
  local temporary_file
  if [[ -e $BBR_MODULE_FILE ]] && ! grep -Fqx "$BBR_MODULE_MARKER" "$BBR_MODULE_FILE"; then
    warn "BBR 已临时加载；拒绝覆盖非本工具模块配置：$BBR_MODULE_FILE。"
    return 1
  fi
  [[ -d $(dirname "$BBR_MODULE_FILE") ]] || mkdir -p "$(dirname "$BBR_MODULE_FILE")"
  temporary_file=$(mktemp "${BBR_MODULE_FILE}.XXXXXX")
  { printf '%s\n' "$BBR_MODULE_MARKER"; printf '%s\n' 'tcp_bbr'; } >"$temporary_file"
  chmod 644 "$temporary_file"; mv -f "$temporary_file" "$BBR_MODULE_FILE"
}
remove_bbr_module_config() {
  [[ -f $BBR_MODULE_FILE ]] && grep -Fqx "$BBR_MODULE_MARKER" "$BBR_MODULE_FILE" && rm -f "$BBR_MODULE_FILE"
}
ensure_bbr() {
  kernel_supports_bbr && return 0
  (( DRY_RUN )) && fail '预览模式不会加载 tcp_bbr；当前内核尚未提供 BBR。'
  require_command modprobe
  say '当前内核未列出 BBR，正在尝试加载已有 tcp_bbr 模块。'
  modprobe tcp_bbr 2>/dev/null || fail '无法加载 tcp_bbr；商家内核可能未提供该模块，工具不会下载模块或替换内核。'
  kernel_supports_bbr || fail 'tcp_bbr 已尝试加载，但内核仍未提供 BBR；已停止调优。'
  if write_bbr_module_config; then
    BBR_MODULE_CONFIG_CREATED=1
    ok 'BBR 已启用；本工具会在重启后自动加载 tcp_bbr。'
  else
    warn 'BBR 已在本次启动中启用；因同名模块配置不归本工具管理，未改动其重启加载行为。'
  fi
}
cleanup_candidate_bbr() {
  (( BBR_MODULE_CONFIG_CREATED )) || return 0
  remove_bbr_module_config
  BBR_MODULE_CONFIG_CREATED=0
}
memory_mib() { awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo; }
default_interface() { ip route show default 2>/dev/null | awk 'NR == 1 {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'; }
virtualization() { systemd-detect-virt 2>/dev/null || printf 'unknown'; }

validate_common() {
  case "$ROLE" in general|proxy|server) ;; *) fail '--role 只能是 general、proxy 或 server。' ;; esac
  is_positive_integer "$PEER_PORT" && (( PEER_PORT <= 65535 )) || fail '--port 必须是 1 到 65535 的整数。'
  is_positive_integer "$DURATION" && (( DURATION <= 120 )) || fail '--duration 必须是 1 到 120 的整数。'
  is_positive_integer "$WORKERS" && (( WORKERS <= 32 )) || fail '--workers 必须是 1 到 32 的整数。'
  is_positive_integer "$ROUNDS" && (( ROUNDS <= 5 )) || fail '--rounds 必须是 1 到 5 的整数。'
  is_positive_integer "$POLICER_ROUNDS" && (( POLICER_ROUNDS >= 2 && POLICER_ROUNDS <= 5 )) || fail '--policer-rounds 必须是 2 到 5 的整数。'
  is_positive_integer "$PEER_MAX_RTT" && (( PEER_MAX_RTT <= 1000 )) || fail '--peer-max-rtt 必须是 1 到 1000 的整数。'
  is_positive_integer "$MAX_TEST_GIB" && (( MAX_TEST_GIB <= 10000 )) || fail '--max-test-gib 必须是 1 到 10000 的整数。'
  is_positive_integer "$MAX_RATE_SPREAD_PERCENT" && (( MAX_RATE_SPREAD_PERCENT <= 200 )) || fail '--max-rate-spread 必须是 1 到 200 的整数。'
  [[ $INITCWND =~ ^(0|[1-9][0-9]*)$ ]] && (( INITCWND <= 64 )) || fail '--initcwnd 必须为 0 到 64；0 表示不调整初始窗口。'
  [[ -z $BANDWIDTH_MBIT ]] || { is_positive_integer "$BANDWIDTH_MBIT" && (( BANDWIDTH_MBIT <= 100000 )) || fail '--bandwidth 必须是 1 到 100000 的整数。'; }
  [[ -z $RTT_MS ]] || { is_positive_integer "$RTT_MS" && (( RTT_MS <= 3000 )) || fail '--rtt 必须是 1 到 3000 的整数。'; }
}
validate_peer() { [[ -n $PEER ]] || fail '未取得可用 iperf3 对端。'; [[ $PEER =~ ^[A-Za-z0-9._-]+$ ]] || fail '--peer 仅允许域名或 IPv4 地址；IPv6 请用 DNS 名称。'; }

auto_pick_peer() {
  local candidate location provider rtt ranked host port probe
  if (( ! ALLOW_PUBLIC_PEERS )); then
    warn '自动选择会向内置的 Leaseweb、OVH、Clouvider 等第三方节点发送 ping、TCP 探测和短时 iperf3 流量；对端会看到本机公网 IP。'
    if [[ -t 0 && -t 1 ]]; then
      local answer
      yellow '[确认] 允许本次使用第三方公共测速节点吗？ [y/N] '
      read -r answer
      [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]] || fail '未获公共节点授权，已停止；可改用 --peer 指定自有/可信对端。'
      ALLOW_PUBLIC_PEERS=1
    else
      fail '非交互自动选点必须显式加入 --allow-public-peers；更推荐用 --peer 指定自有/可信对端。'
    fi
  fi
  say '未指定 --peer，正在从内置公共 iperf3 节点中自动选择可用且 RTT 较低的对端。'
  command -v ping >/dev/null 2>&1 || warn '未安装 ping，将按节点顺序测试；建议安装 iputils-ping 以获得更准确的自动选择。'
  ranked=''
  while IFS='|' read -r candidate location provider; do
    [[ -n $candidate ]] || continue
    rtt='9999'
    if command -v ping >/dev/null 2>&1; then
      rtt=$(ping -n -c 2 -W 2 "$candidate" 2>/dev/null | awk -F'/' '/min\/avg\/max|round-trip/ {printf "%.0f", $5}' | tail -n 1 || true)
      [[ -n $rtt ]] || rtt='9999'
    fi
    ranked+="$rtt|$candidate|$location|$provider"$'\n'
  done <<<"$PUBLIC_PEERS"
  while IFS='|' read -r rtt host location provider; do
    [[ -n $host ]] || continue
    if (( rtt > PEER_MAX_RTT )) && command -v ping >/dev/null 2>&1; then
      say "跳过过远节点：$location / $provider（RTT 约 ${rtt}ms，阈值 ${PEER_MAX_RTT}ms）。"
      continue
    fi
    say "尝试公共节点：$location / $provider（RTT 约 ${rtt}ms）。"
    for port in "${IPERF_PORTS[@]}"; do
      # 先只做 TCP 握手；避免对每个端口都跑秒级满速 iperf3 测试。
      timeout 4 bash -c 'cat < /dev/null > "/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null || continue
      probe=$(timeout 8 iperf3 -c "$host" -p "$port" -P 1 -t 2 2>&1) || continue
      if [[ $probe == *'receiver'* ]]; then
        PEER=$host; PEER_PORT=$port
        ok "已选择公共对端：$PEER:$PEER_PORT（$location / $provider）。"
        return 0
      fi
    done
  done < <(printf '%s' "$ranked" | sort -n -t '|' -k 1,1)
  fail '未找到可用公共 iperf3 对端。请稍后重试，或使用 --peer 指定自有/可信对端。'
}

ensure_iperf3() {
  command -v iperf3 >/dev/null 2>&1 && return 0
  (( NO_INSTALL )) && fail '未安装 iperf3，且指定了 --no-install。请自行安装后重试。'
  warn '自适应测试需要 iperf3；仅在你确认后安装该系统包，不会执行远程脚本。'
  confirm '安装 iperf3 吗？' || fail '未安装 iperf3，已取消。'
  if command -v apt-get >/dev/null 2>&1; then apt-get install -y iperf3
  elif command -v dnf >/dev/null 2>&1; then dnf install -y iperf3
  elif command -v yum >/dev/null 2>&1; then yum install -y iperf3
  elif command -v apk >/dev/null 2>&1; then apk add iperf3
  else fail '无法识别包管理器，请手动安装 iperf3。'; fi
  command -v iperf3 >/dev/null 2>&1 || fail 'iperf3 安装后仍不可用。'
}

rate_to_mbit() {
  awk -v n="$1" -v u="$2" 'BEGIN {if(u~/^K/)n=n/1000; else if(u~/^G/)n=n*1000; else if(u~/^T/)n=n*1000000; printf "%.0f",n}'
}
transfer_to_mib() {
  awk -v n="$1" -v u="$2" 'BEGIN {if(u=="Bytes")n=n/1048576; else if(u=="KBytes")n=n/1024; else if(u=="GBytes")n=n*1024; else if(u=="TBytes")n=n*1048576; printf "%.0f",n}'
}
retrans_per_gib() {
  local retrans=$1 transfer_mib=$2
  (( transfer_mib > 0 )) || { printf '0'; return; }
  awk -v r="$retrans" -v m="$transfer_mib" 'BEGIN {printf "%.0f", r*1024/m}'
}
guard_test_traffic() {
  local label=$1 rate=$2 tests=$3 estimated_gib
  is_positive_integer "$rate" || return 0
  estimated_gib=$(awk -v r="$rate" -v d="$DURATION" -v n="$tests" 'BEGIN {g=r*d*n*1000000/8/1073741824; printf "%d", (g==int(g)?g:int(g)+1)}')
  say "$label：按 ${rate}Mbit/s、${tests} 次、每次 ${DURATION}s 估算，最多约 ${estimated_gib} GiB。"
  (( estimated_gib <= MAX_TEST_GIB )) && return 0
  if (( ALLOW_HIGH_TRAFFIC )); then
    warn "估算流量超过 ${MAX_TEST_GIB} GiB，但已由 --allow-high-traffic 明确授权。"
    return 0
  fi
  MEASURE_FAILURE="$label 估算约 ${estimated_gib} GiB，超过上限 ${MAX_TEST_GIB} GiB"
  warn "$MEASURE_FAILURE；尚未发送该阶段测速流量。交互向导可选择只做基础调优，命令行需显式加入 --allow-high-traffic。"
  return 1
}
MEASURE_RATE=''; MEASURE_RETRANS=''; MEASURE_RETRANS_PER_GIB=''; MEASURE_TRANSFER_MIB=''; MEASURE_RATE_SPREAD=''; MEASURE_NOISY=0
MEASURE_REVERSE_RATE=''; MEASURE_REVERSE_RETRANS_PER_GIB=''; MEASURE_REVERSE_TRANSFER_MIB=''; MEASURE_REVERSE_RATE_SPREAD=''; MEASURE_REVERSE_NOISY=0
MEASURE_RTT=''; MEASURE_FAILURE=''
DIRECTION_RATE=''; DIRECTION_RETRANS=''; DIRECTION_RETRANS_PER_GIB=''; DIRECTION_TRANSFER_MIB=''; DIRECTION_RATE_SPREAD=''; DIRECTION_NOISY=0
MEASURE_STAGE_TRANSFER_MIB=0

measure_rtt() {
  MEASURE_RTT=''; command -v ping >/dev/null 2>&1 || return 0
  local summary
  summary=$(ping -n -c 4 -W 2 "$PEER" 2>/dev/null | awk -F' = ' '/min\/avg\/max/ {print $2}' | tail -n 1 || true)
  [[ -n $summary ]] && MEASURE_RTT=$(awk -F/ '{printf "%.0f",$2}' <<<"$summary")
}
parse_iperf_result() {
  local output=$1 raw transfer raw_rate raw_unit raw_transfer raw_transfer_unit
  raw=$(awk '$NF == "receiver" {for(i=1;i<=NF;i++)if($i~/^[KMGTP]?bits\/sec$/){rate=$(i-1);unit=$i}} END{if(rate!="")print rate,unit}' <<<"$output")
  [[ -n $raw ]] || return 1
  raw_rate=${raw%% *}; raw_unit=${raw##* }; MEASURE_RATE=$(rate_to_mbit "$raw_rate" "$raw_unit")
  MEASURE_RETRANS=$(awk '$NF == "sender" {value=$(NF-1)} END{if(value!="")print value;else print 0}' <<<"$output")
  transfer=$(awk '$NF == "sender" {for(i=1;i<=NF;i++)if($i~/^(Bytes|KBytes|MBytes|GBytes|TBytes)$/){amount=$(i-1);unit=$i}} END{if(amount!="")print amount,unit}' <<<"$output")
  [[ -n $transfer && $MEASURE_RETRANS =~ ^[0-9]+$ ]] || return 1
  raw_transfer=${transfer%% *}; raw_transfer_unit=${transfer##* }
  MEASURE_TRANSFER_MIB=$(transfer_to_mib "$raw_transfer" "$raw_transfer_unit")
  (( MEASURE_TRANSFER_MIB > 0 )) || return 1
}
compact_iperf_error() {
  awk 'NF {line=$0} END {gsub(/[[:cntrl:]]/, " ", line); if (line != "") print substr(line, 1, 180)}' <<<"$1"
}
run_measure_iperf() {
  local direction=${1:-forward} port output last_error='' seen_ports=''
  local -a command=()
  MEASURE_FAILURE=''
  for port in "$PEER_PORT" "${IPERF_PORTS[@]}"; do
    [[ " $seen_ports " == *" $port "* ]] && continue
    seen_ports+=" $port"
    command=(timeout "$(( DURATION + 15 ))" iperf3 -c "$PEER" -p "$port" -P "$WORKERS" -t "$DURATION" --omit 2)
    [[ $direction == reverse ]] && command+=(-R)
    output=$("${command[@]}" 2>&1) || {
      last_error=$(compact_iperf_error "$output")
      continue
    }
    if parse_iperf_result "$output"; then
      if [[ $port != "$PEER_PORT" ]]; then
        warn "对端端口 $PEER_PORT 不可用，已切换到同一对端的可用端口 $port。"
        PEER_PORT=$port
      fi
      return 0
    fi
    last_error=$(compact_iperf_error "$output")
  done
  MEASURE_FAILURE=${last_error:-"对端 $PEER 的全部 iperf3 端口无响应或测试超时"}
  return 1
}
measure_direction() {
  local direction=$1 label=$2 temporary_file inlier_file='' stats_file round valid required rate retrans transfer_mib
  local median_position minimum maximum actual_transfer_mib metric_transfer_mib inliers discarded
  DIRECTION_RATE=''; DIRECTION_RETRANS=''; DIRECTION_RETRANS_PER_GIB=''; DIRECTION_TRANSFER_MIB=''; DIRECTION_RATE_SPREAD=''; DIRECTION_NOISY=0
  temporary_file=$(mktemp)
  chmod 600 "$temporary_file"
  valid=0
  required=$(( ROUNDS / 2 + 1 ))
  say "开始${label} ${ROUNDS} 轮测试：并发=$WORKERS，单轮=${DURATION}s。"
  for ((round = 1; round <= ROUNDS; round += 1)); do
    if ! run_measure_iperf "$direction"; then
      warn "${label}第 $round 轮失败（已尝试同一对端的备用端口）：$MEASURE_FAILURE"
      continue
    fi
    rate=$MEASURE_RATE; retrans=$MEASURE_RETRANS; transfer_mib=$MEASURE_TRANSFER_MIB
    printf '%s\t%s\t%s\n' "$rate" "$retrans" "$transfer_mib" >>"$temporary_file"
    valid=$(( valid + 1 ))
    MEASURE_STAGE_TRANSFER_MIB=$(( MEASURE_STAGE_TRANSFER_MIB + transfer_mib ))
    say "${label}第 $round 轮：${rate} Mbit/s，重传 ${retrans}，传输约 ${transfer_mib} MiB。"
    if (( ALLOW_HIGH_TRAFFIC == 0 && MEASURE_STAGE_TRANSFER_MIB > MAX_TEST_GIB * 1024 )); then
      rm -f "$temporary_file"
      MEASURE_FAILURE="本阶段实际传输 ${MEASURE_STAGE_TRANSFER_MIB} MiB，已超过 ${MAX_TEST_GIB} GiB 上限"
      warn "$MEASURE_FAILURE；停止剩余测速。需要继续时显式加入 --allow-high-traffic。"
      return 1
    fi
  done
  if (( valid < required )); then
    rm -f "$temporary_file"
    MEASURE_FAILURE="${label}仅 $valid/$ROUNDS 轮有效，少于所需的 $required 轮"
    warn "$MEASURE_FAILURE；拒绝据此调优。"
    return 1
  fi
  actual_transfer_mib=$(awk -F'\t' '{total += $3} END {printf "%.0f", total}' "$temporary_file")
  stats_file=$temporary_file
  median_position=$(( (valid + 1) / 2 ))
  DIRECTION_RATE=$(sort -n -k 1,1 "$stats_file" | awk -v position="$median_position" 'NR == position {print $1}')
  minimum=$(sort -n -k 1,1 "$stats_file" | awk 'NR==1{print $1}')
  maximum=$(sort -n -k 1,1 "$stats_file" | awk 'END{print $1}')
  DIRECTION_RATE_SPREAD=$(awk -v low="$minimum" -v high="$maximum" -v median="$DIRECTION_RATE" 'BEGIN {if(median>0)printf "%.0f",(high-low)*100/median;else print 999}')
  if (( DIRECTION_RATE_SPREAD > MAX_RATE_SPREAD_PERCENT && valid >= 5 )); then
    inlier_file=$(mktemp); chmod 600 "$inlier_file"
    awk -F'\t' -v median="$DIRECTION_RATE" -v threshold="$MAX_RATE_SPREAD_PERCENT" '
      {deviation=$1-median; if(deviation<0)deviation=-deviation; if(median>0 && deviation*100/median<=threshold)print}
    ' "$temporary_file" >"$inlier_file"
    inliers=$(awk 'END{print NR}' "$inlier_file")
    if (( inliers >= required )); then
      discarded=$(( valid - inliers )); stats_file=$inlier_file; valid=$inliers
      DIRECTION_NOISY=1
      warn "${label}检测到 $discarded 轮明显离群样本；已使用占多数的稳定样本簇，其余流量仍计入上限。"
      median_position=$(( (valid + 1) / 2 ))
      DIRECTION_RATE=$(sort -n -k 1,1 "$stats_file" | awk -v position="$median_position" 'NR == position {print $1}')
      minimum=$(sort -n -k 1,1 "$stats_file" | awk 'NR==1{print $1}')
      maximum=$(sort -n -k 1,1 "$stats_file" | awk 'END{print $1}')
      DIRECTION_RATE_SPREAD=$(awk -v low="$minimum" -v high="$maximum" -v median="$DIRECTION_RATE" 'BEGIN {if(median>0)printf "%.0f",(high-low)*100/median;else print 999}')
    fi
  fi
  if (( DIRECTION_RATE_SPREAD > MAX_RATE_SPREAD_PERCENT )); then
    rm -f "$temporary_file"; [[ -z $inlier_file ]] || rm -f "$inlier_file"
    MEASURE_FAILURE="${label}多轮吞吐波动 ${DIRECTION_RATE_SPREAD}%（${minimum}-${maximum} Mbit/s），超过 ${MAX_RATE_SPREAD_PERCENT}% 上限"
    warn "$MEASURE_FAILURE；当前对端或线路不稳定，拒绝据此调优。"
    return 1
  fi
  DIRECTION_RETRANS=$(awk -F'\t' '{total += $2} END {printf "%.0f", total}' "$stats_file")
  metric_transfer_mib=$(awk -F'\t' '{total += $3} END {printf "%.0f", total}' "$stats_file")
  DIRECTION_TRANSFER_MIB=$actual_transfer_mib
  DIRECTION_RETRANS_PER_GIB=$(retrans_per_gib "$DIRECTION_RETRANS" "$metric_transfer_mib")
  rm -f "$temporary_file"; [[ -z $inlier_file ]] || rm -f "$inlier_file"
  say "${label}汇总：中位 ${DIRECTION_RATE} Mbit/s；重传 ${DIRECTION_RETRANS}；约 ${DIRECTION_RETRANS_PER_GIB} 次/GiB；波动 ${DIRECTION_RATE_SPREAD}%。"
}
measure() {
  require_linux; require_command timeout; validate_common; ensure_iperf3
  [[ -n $PEER ]] || auto_pick_peer
  validate_peer
  local tests=$ROUNDS combined_mib
  MEASURE_STAGE_TRANSFER_MIB=0
  MEASURE_NOISY=0; MEASURE_REVERSE_NOISY=0
  MEASURE_REVERSE_RATE=''; MEASURE_REVERSE_RETRANS_PER_GIB=''; MEASURE_REVERSE_TRANSFER_MIB=''; MEASURE_REVERSE_RATE_SPREAD=''
  (( BIDIRECTIONAL )) && tests=$(( ROUNDS * 2 ))
  guard_test_traffic '本轮测速' "$BANDWIDTH_MBIT" "$tests" || return 1
  if (( BIDIRECTIONAL )); then
    say "测速对端=$PEER:$PEER_PORT；先测 VPS 出站，再用 iperf3 -R 测 VPS 入站。"
  else
    say "测速对端=$PEER:$PEER_PORT；本次按 --forward-only 只测 VPS 出站。"
  fi
  say '多轮吞吐波动超过阈值时会判定样本不可靠，不会用于调优。'
  if ! measure_direction forward '出站'; then return 1; fi
  MEASURE_RATE=$DIRECTION_RATE; MEASURE_RETRANS=$DIRECTION_RETRANS; MEASURE_RETRANS_PER_GIB=$DIRECTION_RETRANS_PER_GIB
  MEASURE_TRANSFER_MIB=$DIRECTION_TRANSFER_MIB; MEASURE_RATE_SPREAD=$DIRECTION_RATE_SPREAD; MEASURE_NOISY=$DIRECTION_NOISY
  if (( BIDIRECTIONAL )); then
    if ! measure_direction reverse '入站'; then return 1; fi
    MEASURE_REVERSE_RATE=$DIRECTION_RATE; MEASURE_REVERSE_RETRANS_PER_GIB=$DIRECTION_RETRANS_PER_GIB
    MEASURE_REVERSE_TRANSFER_MIB=$DIRECTION_TRANSFER_MIB; MEASURE_REVERSE_RATE_SPREAD=$DIRECTION_RATE_SPREAD; MEASURE_REVERSE_NOISY=$DIRECTION_NOISY
  fi
  measure_rtt
  combined_mib=$(( MEASURE_TRANSFER_MIB + ${MEASURE_REVERSE_TRANSFER_MIB:-0} ))
  line
  say "出站：${MEASURE_RATE} Mbit/s；重传 ${MEASURE_RETRANS_PER_GIB} 次/GiB；波动 ${MEASURE_RATE_SPREAD}%。"
  if (( BIDIRECTIONAL )); then say "入站：${MEASURE_REVERSE_RATE} Mbit/s；重传 ${MEASURE_REVERSE_RETRANS_PER_GIB} 次/GiB；波动 ${MEASURE_REVERSE_RATE_SPREAD}%。"; fi
  say "本阶段实际传输约 ${combined_mib} MiB。"
  say "ping 平均 RTT：${MEASURE_RTT:-未取得} ms。"
  line
}

infer_bandwidth_from_nic() {
  local iface speed
  iface=$(default_interface); command -v ethtool >/dev/null 2>&1 || return 1
  speed=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/ {gsub(/Mb\/s/,"",$2);if($2~/^[0-9]+$/)print $2}')
  [[ -n $speed && $speed != -1 ]] || return 1; printf '%s' "$speed"
}
derive_network_facts() {
  [[ -n $BANDWIDTH_MBIT ]] || { [[ -n $MEASURE_RATE ]] && BANDWIDTH_MBIT=$MEASURE_RATE || BANDWIDTH_MBIT=$(infer_bandwidth_from_nic || true); }
  [[ -n $RTT_MS ]] || fail '无法取得业务目标 RTT；请提供 --rtt。'
  is_positive_integer "$BANDWIDTH_MBIT" || fail '无法推导出口带宽；请提供 --bandwidth 或使用 --peer 测试。'
  is_positive_integer "$RTT_MS" || fail '无法取得 RTT；请提供 --rtt（例如中国方向常用 150）。'
}
estimate_buffer_bandwidth() {
  local observed=$1 target tier
  is_positive_integer "$observed" || return 1
  target=$(( (observed * AUTO_BUFFER_HEADROOM_PERCENT + 99) / 100 ))
  # 公共 iperf3 对端常先成为瓶颈。缓冲区上限不是预分配，因此自动模式按
  # 1.5 倍实测值向上取常见端口档位，避免一次偏低测速永久压小高 BDP 窗口。
  for tier in 100 200 300 500 1000 2000 3000 5000 10000 20000 40000 100000; do
    if (( target <= tier )); then printf '%s' "$tier"; return 0; fi
  done
  printf '100000'
}
calculate_buffer() {
  local bdp multiplier cap result memory buffer_bandwidth
  memory=$(memory_mib); multiplier=2
  [[ -z $BUFFER_MULTIPLIER_OVERRIDE ]] || multiplier=$BUFFER_MULTIPLIER_OVERRIDE
  buffer_bandwidth=${BUFFER_BANDWIDTH_MBIT:-$BANDWIDTH_MBIT}
  # BDP（字节）= 带宽 Mbit/s × RTT ms × 125；不能遗漏 Mbit/ms 到字节的单位换算。
  bdp=$(( buffer_bandwidth * RTT_MS * 125 )); cap=$(( memory * 1024 * 1024 / 32 )); (( cap > 268435456 )) && cap=268435456
  result=$(( bdp * multiplier + 2097152 )); (( result < 4194304 )) && result=4194304; (( result > cap )) && result=$cap; (( result < 4194304 )) && result=4194304
  printf '%s' "$result"
}
calculate_tcp_mem() {
  local bytes pages page_size
  bytes=$(( $(memory_mib) * 1024 * 1024 ))
  page_size=$(getconf PAGESIZE) || return 1
  is_positive_integer "$page_size" || return 1
  pages=$(( bytes / page_size ))
  printf '%s %s %s' "$(( pages / 16 ))" "$(( pages / 8 ))" "$(( pages / 4 ))"
}
calculate_initial_rmem() {
  local ceiling=$1 initial
  # 高 BDP 单流从过小的初始缓冲起步会浪费多个 RTT。1MiB 与 tcpfit 的
  # proxy 起点一致；全局 tcp_mem 压力阈值仍限制总内存，并非每条连接预分配上限。
  case "$ROLE" in
    proxy) initial=1048576 ;;
    server) initial=524288 ;;
    *) initial=1048576 ;;
  esac
  (( initial > ceiling )) && initial=$ceiling
  printf '%s' "$initial"
}
calculate_initial_wmem() {
  local ceiling=$1 initial
  # 代理/通用单流使用 1MiB 起点，避免 200ms 级路径从 16/256KiB 慢慢爬升。
  # server 角色保持较保守；所有角色仍受单 socket 上限与 tcp_mem 总预算约束。
  case "$ROLE" in
    proxy) initial=1048576 ;;
    server) initial=262144 ;;
    *) initial=1048576 ;;
  esac
  (( initial > ceiling )) && initial=$ceiling
  printf '%s' "$initial"
}
calculate_backlog() { if (( BANDWIDTH_MBIT >= 5000 )); then printf 32768; else printf 16384; fi; }

declare -a KEYS=() VALUES=()
add_setting() { sysctl_exists "$1" || { warn "内核不支持 $1，已跳过。"; return 0; }; KEYS+=("$1"); VALUES+=("$2"); }
set_setting_value() {
  local setting_key=$1 value=$2 index
  for index in "${!KEYS[@]}"; do
    if [[ ${KEYS[$index]} == "$setting_key" ]]; then VALUES[$index]=$value; return 0; fi
  done
  return 1
}
drop_setting() {
  local setting_key=$1 index
  local -a kept_keys=() kept_values=()
  for index in "${!KEYS[@]}"; do
    [[ ${KEYS[$index]} == "$setting_key" ]] && continue
    kept_keys+=("${KEYS[$index]}"); kept_values+=("${VALUES[$index]}")
  done
  KEYS=("${kept_keys[@]}"); VALUES=("${kept_values[@]}")
}
build_settings() {
  local buffer initial_rmem initial_wmem backlog socket_queue syn_queue
  KEYS=(); VALUES=()
  buffer=$(calculate_buffer); initial_rmem=$(calculate_initial_rmem "$buffer"); initial_wmem=$(calculate_initial_wmem "$buffer"); backlog=$(calculate_backlog); case "$ROLE" in proxy|server) socket_queue=8192; syn_queue=8192 ;; *) socket_queue=4096; syn_queue=4096 ;; esac
  # BBR 配合 FQ pacing。default_qdisc 影响后续新建队列；标准模式还会对
  # 当前活动根 qdisc 保存精确快照后切换 FQ，深度模式则通过 A/B 决定。
  add_setting net.ipv4.tcp_congestion_control bbr
  if (( QDISC_EXPERIMENT )); then add_setting net.core.default_qdisc "$(sysctl_value net.core.default_qdisc)"
  else add_setting net.core.default_qdisc fq
  fi
  add_setting net.core.rmem_max "$buffer"; add_setting net.core.wmem_max "$buffer"
  add_setting net.ipv4.tcp_rmem "4096 $initial_rmem $buffer"; add_setting net.ipv4.tcp_wmem "4096 $initial_wmem $buffer"
  add_setting net.ipv4.tcp_mem "$(calculate_tcp_mem)"
  add_setting net.ipv4.tcp_window_scaling 1; add_setting net.ipv4.tcp_moderate_rcvbuf 1
  # 修复其它“优化脚本”最常留下的有损链路退化项。SACK/DSACK/timestamps 都是
  # Linux 默认开启的标准能力；显式恢复后，旧配置把它们关掉也不会让跨境单流
  # 在少量丢包下退回到超时恢复。tcp_no_metrics_save=0 同样恢复内核默认行为。
  add_setting net.ipv4.tcp_sack 1; add_setting net.ipv4.tcp_dsack 1
  add_setting net.ipv4.tcp_timestamps 1; add_setting net.ipv4.tcp_no_metrics_save 0
  # 恢复现代 Linux 的 TLP + RACK 丢包检测基线，并撤销某些旧脚本设置的
  # tcp_reordering=300。较高的固定重排序阈值会延迟高 RTT 路径上的快速重传。
  add_setting net.ipv4.tcp_early_retrans 3; add_setting net.ipv4.tcp_recovery 1
  add_setting net.ipv4.tcp_reordering 3; add_setting net.ipv4.tcp_fastopen 3
  add_setting net.ipv4.tcp_mtu_probing 1; add_setting net.ipv4.tcp_slow_start_after_idle 0
  add_setting net.core.netdev_max_backlog "$backlog"; add_setting net.core.netdev_budget 600
  add_setting net.core.somaxconn "$socket_queue"; add_setting net.ipv4.tcp_max_syn_backlog "$syn_queue"
  [[ $ROLE != proxy ]] || add_setting net.ipv4.ip_local_port_range '10240 65535'
  ((${#KEYS[@]})) || fail '没有可写入的调优项。'
}

active_root_qdisc() { tc qdisc show dev "$1" 2>/dev/null | awk 'NR == 1 {print $2}'; }
active_htb_rate() { tc class show dev "$1" 2>/dev/null | awk '{for (i = 1; i <= NF; i += 1) if ($i == "rate") {print $(i + 1); exit}}'; }
show_environment() {
  local iface root_qdisc htb_rate sack dsack timestamps
  iface=$(default_interface); line; say "版本：$VERSION；内核：$(uname -r)；虚拟化：$(virtualization)"
  say "内存：$(memory_mib) MiB；默认网卡：${iface:-未检测到}"; say "拥塞控制：$(sysctl_value net.ipv4.tcp_congestion_control)；默认 qdisc：$(sysctl_value net.core.default_qdisc)"
  sack=$(sysctl_value net.ipv4.tcp_sack); dsack=$(sysctl_value net.ipv4.tcp_dsack); timestamps=$(sysctl_value net.ipv4.tcp_timestamps)
  say "丢包恢复：SACK=${sack:-不支持}；DSACK=${dsack:-不支持}；timestamps=${timestamps:-不支持}"
  if [[ $sack == 0 || $dsack == 0 || $timestamps == 0 ]]; then
    warn '检测到标准 TCP 丢包恢复能力被关闭；这会让高延迟、有少量丢包的单线程吞吐严重下降。'
  fi
  if [[ -n $iface ]]; then
    root_qdisc=$(active_root_qdisc "$iface")
    say "活动根 qdisc：${root_qdisc:-未检测到}"
    if [[ $root_qdisc == htb ]]; then
      htb_rate=$(active_htb_rate "$iface")
      warn "检测到已有 HTB 出向整形（首个 class rate：${htb_rate:-未取得}）。本工具不会覆盖它；实际出站速度仍受该整形限制。"
    fi
  fi
  line
}
show_plan() {
  local i buffer initial_rmem initial_wmem buffer_bandwidth; buffer=$(calculate_buffer); initial_rmem=$(calculate_initial_rmem "$buffer"); initial_wmem=$(calculate_initial_wmem "$buffer"); buffer_bandwidth=${BUFFER_BANDWIDTH_MBIT:-$BANDWIDTH_MBIT}; show_environment
  say "用途=$ROLE；带宽=${BANDWIDTH_MBIT} Mbit/s；业务目标 RTT=${RTT_MS} ms；推导缓冲区上限=${buffer} 字节；初始接收/发送缓冲区=${initial_rmem}/${initial_wmem} 字节。"
  [[ -z $BUFFER_BANDWIDTH_MBIT ]] || say "自动测速只代表当时对端能力；窗口容量按 ${buffer_bandwidth} Mbit/s 端口档位推导，实测吞吐仍按 ${BANDWIDTH_MBIT} Mbit/s 记录。"
  say '缓冲区采用 BDP 倍率 + 2MiB 余量；单 socket 上限受内存 1/32 及 256MiB 约束。'
  say '将显式恢复 SACK、DSACK、TCP timestamps、TLP/RACK 与正常乱序阈值，防止旧调优配置拖垮高延迟有损单流。'
  for i in "${!KEYS[@]}"; do say "${KEYS[$i]}：$(sysctl_value "${KEYS[$i]}") -> ${VALUES[$i]}"; done
  if (( QDISC_EXPERIMENT )); then say '基础候选先保持原活动 qdisc；深度阶段会临时 A/B 测试 FQ，未胜出即精确恢复。'
  else say '将把默认 qdisc 设为 fq，并在精确保存当前活动队列后切换为 FQ；回滚会恢复原队列。'; fi
}

snapshot_if_needed() {
  if [[ -e $CONFIG_FILE ]] && ! grep -Fqx "$MARKER" "$CONFIG_FILE"; then fail "拒绝覆盖非本工具配置：$CONFIG_FILE"; fi
  install -d -m 700 "$STATE_DIR"
  local tmp i changed=0
  tmp=$(mktemp "$STATE_DIR/baseline.XXXXXX"); chmod 600 "$tmp"
  [[ -f $SNAPSHOT_FILE ]] && cat "$SNAPSHOT_FILE" >"$tmp"
  for i in "${!KEYS[@]}"; do
    if [[ ! -f $SNAPSHOT_FILE ]] || ! awk -F'\t' -v wanted="${KEYS[$i]}" '$1 == wanted { found=1 } END { exit !found }' "$SNAPSHOT_FILE"; then
      printf '%s\t%s\n' "${KEYS[$i]}" "$(sysctl_value "${KEYS[$i]}")" >>"$tmp"
      changed=1
    fi
  done
  if [[ ! -f $SNAPSHOT_FILE || $changed -eq 1 ]]; then mv -f "$tmp" "$SNAPSHOT_FILE"; else rm -f "$tmp"; fi
}
snapshot_transaction() {
  install -d -m 700 "$STATE_DIR"
  local tmp i
  tmp=$(mktemp "$STATE_DIR/transaction.XXXXXX"); chmod 600 "$tmp"
  for i in "${!KEYS[@]}"; do printf '%s\t%s\n' "${KEYS[$i]}" "$(sysctl_value "${KEYS[$i]}")" >>"$tmp"; done
  mv -f "$tmp" "$TRANSACTION_FILE"
}
snapshot_config_transaction() {
  rm -f "$CONFIG_TRANSACTION_FILE" "$CONFIG_TRANSACTION_ABSENT"
  if [[ -f $CONFIG_FILE ]]; then
    cp -p -- "$CONFIG_FILE" "$CONFIG_TRANSACTION_FILE"
  else
    : >"$CONFIG_TRANSACTION_ABSENT"
    chmod 600 "$CONFIG_TRANSACTION_ABSENT"
  fi
}
restore_config_transaction() {
  if [[ -f $CONFIG_TRANSACTION_FILE ]]; then
    mv -f -- "$CONFIG_TRANSACTION_FILE" "$CONFIG_FILE"
  elif [[ -f $CONFIG_TRANSACTION_ABSENT ]]; then
    rm -f -- "$CONFIG_FILE" "$CONFIG_TRANSACTION_ABSENT"
  fi
}
restore_transaction_values() {
  local key value failed=0
  [[ -f $TRANSACTION_FILE ]] || return 0
  while IFS=$'\t' read -r key value; do
    [[ -z $key ]] && continue
    if ! sysctl_exists "$key" || ! sysctl -q -w "$key=$value"; then
      warn "恢复本次修改前的 $key 失败。"
      failed=1
    fi
  done <"$TRANSACTION_FILE"
  return "$failed"
}
discard_transaction() { rm -f "$TRANSACTION_FILE" "$CONFIG_TRANSACTION_FILE" "$CONFIG_TRANSACTION_ABSENT"; }
abort_transaction() {
  cleanup_candidate_bbr
  local failed=0
  restore_config_transaction || failed=1
  restore_transaction_values || failed=1
  if (( failed == 0 )); then
    discard_transaction
    return 0
  fi
  warn "部分参数恢复失败；事务快照已保留：$TRANSACTION_FILE"
  return 1
}
write_facts() {
  install -d -m 700 "$STATE_DIR"
  local tmp selected_qdisc=unchanged
  if (( QDISC_SELECTED_FQ )) || [[ -f $QDISC_TUNE_STATE ]]; then selected_qdisc=fq; fi
  tmp=$(mktemp "$STATE_DIR/facts.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! { printf 'role\t%s\n' "$ROLE"; printf 'bandwidth_mbit\t%s\n' "$BANDWIDTH_MBIT"; printf 'buffer_bandwidth_mbit\t%s\n' "${BUFFER_BANDWIDTH_MBIT:-$BANDWIDTH_MBIT}"; printf 'target_rtt_ms\t%s\n' "$RTT_MS"; printf 'test_peer_rtt_ms\t%s\n' "${MEASURE_RTT:-}"; printf 'noisy_link\t%s\n' "$NOISY_LINK"; printf 'buffer_bdp_multiplier\t%s\n' "${BUFFER_MULTIPLIER_OVERRIDE:-default}"; printf 'selected_qdisc\t%s\n' "$selected_qdisc"; printf 'tcp_initial_rmem\t%s\n' "$(calculate_initial_rmem "$(calculate_buffer)")"; printf 'tcp_initial_wmem\t%s\n' "$(calculate_initial_wmem "$(calculate_buffer)")"; printf 'peer\t%s\n' "$PEER"; printf 'measured_egress_mbit\t%s\n' "${MEASURE_RATE:-}"; printf 'measured_egress_retrans_per_gib\t%s\n' "${MEASURE_RETRANS_PER_GIB:-}"; printf 'measured_egress_spread_percent\t%s\n' "${MEASURE_RATE_SPREAD:-}"; printf 'measured_ingress_mbit\t%s\n' "${MEASURE_REVERSE_RATE:-}"; printf 'measured_ingress_retrans_per_gib\t%s\n' "${MEASURE_REVERSE_RETRANS_PER_GIB:-}"; printf 'measured_ingress_spread_percent\t%s\n' "${MEASURE_REVERSE_RATE_SPREAD:-}"; printf 'facts_end\t1\n'; } >"$tmp"; then
    rm -f "$tmp"; return 1
  fi
  tail -n 1 "$tmp" | grep -Fqx $'facts_end\t1' || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$FACTS_FILE"
}
write_experiment_report() {
  local baseline_rate=$1 baseline_retrans_per_gib=$2 after_rate=$3 after_retrans_per_gib=$4 decision=$5
  local baseline_reverse_rate=${6:-} baseline_reverse_retrans_per_gib=${7:-} after_reverse_rate=${8:-} after_reverse_retrans_per_gib=${9:-} report_file
  install -d -m 700 "$REPORT_DIR"
  report_file="$REPORT_DIR/experiment-$(date -u '+%Y%m%dT%H%M%SZ').tsv"
  {
    printf 'generated_utc\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'decision\t%s\n' "$decision"
    printf 'peer\t%s:%s\n' "$PEER" "$PEER_PORT"
    printf 'role\t%s\n' "$ROLE"
    printf 'rounds\t%s\n' "$ROUNDS"
    printf 'duration_seconds\t%s\n' "$DURATION"
    printf 'workers\t%s\n' "$WORKERS"
    printf 'target_rtt_ms\t%s\n' "$RTT_MS"
    printf 'test_peer_rtt_ms\t%s\n' "${MEASURE_RTT:-}"
    printf 'noisy_link\t%s\n' "$NOISY_LINK"
    printf 'buffer_bdp_multiplier\t%s\n' "${BUFFER_MULTIPLIER_OVERRIDE:-default}"
    printf 'baseline_egress_mbit\t%s\n' "$baseline_rate"
    printf 'baseline_egress_retrans_per_gib\t%s\n' "$baseline_retrans_per_gib"
    printf 'after_egress_mbit\t%s\n' "$after_rate"
    printf 'after_egress_retrans_per_gib\t%s\n' "$after_retrans_per_gib"
    printf 'baseline_ingress_mbit\t%s\n' "$baseline_reverse_rate"
    printf 'baseline_ingress_retrans_per_gib\t%s\n' "$baseline_reverse_retrans_per_gib"
    printf 'after_ingress_mbit\t%s\n' "$after_reverse_rate"
    printf 'after_ingress_retrans_per_gib\t%s\n' "$after_reverse_retrans_per_gib"
    if [[ $after_rate =~ ^[0-9]+$ ]]; then
      awk -v before="$baseline_rate" -v after="$after_rate" 'BEGIN {if (before > 0) printf "gain_percent\t%.2f\n", (after-before)*100/before}'
    fi
  } >"$report_file"
  chmod 600 "$report_file"
  say "实验报告：$report_file"
}
is_material_regression() {
  local baseline_rate=$1 baseline_retrans_per_gib=$2 after_rate=$3 after_retrans_per_gib=$4 label=${5:-链路} allowed_retrans
  REGRESSION_REASON=''
  if (( after_rate * 100 < baseline_rate * 85 )); then
    REGRESSION_REASON="${label}吞吐从 ${baseline_rate} 降至 ${after_rate} Mbit/s，下降超过 15%"
    return 0
  fi
  allowed_retrans=$(( baseline_retrans_per_gib * RETRANS_RELATIVE_MULTIPLIER + RETRANS_PER_GIB_MARGIN ))
  if (( after_retrans_per_gib > RETRANS_PER_GIB_HARD_LIMIT && after_retrans_per_gib > allowed_retrans )); then
    REGRESSION_REASON="${label}重传从 ${baseline_retrans_per_gib} 增至 ${after_retrans_per_gib} 次/GiB（容许上限 ${allowed_retrans}）"
    return 0
  fi
  return 1
}
candidate_retrans_is_acceptable() {
  local baseline=$1 candidate=$2 allowed
  allowed=$(( baseline * 2 + RETRANS_PER_GIB_MARGIN ))
  (( allowed < RETRANS_PER_GIB_HARD_LIMIT )) && allowed=$RETRANS_PER_GIB_HARD_LIMIT
  (( candidate <= allowed ))
}
REGRESSION_REASON=''
revert_auto_experiment() {
  warn '复测失败或出现明显退化，正在恢复本次应用前的 TCP 参数。'
  if abort_transaction; then
    if restore_qdisc_experiment; then
      ok '已恢复本次实验前的 TCP 参数及活动 qdisc；实验报告仍保留。'
      return 0
    fi
    warn 'TCP 参数已恢复，但活动 qdisc 恢复失败；队列快照仍保留。'
    return 1
  fi
  restore_qdisc_experiment >/dev/null 2>&1 || true
  return 1
}
abort_auto_on_signal() {
  warn '收到中断信号，正在恢复本次自动实验。'
  if (( TUNING_APPLIED )); then
    abort_transaction >/dev/null 2>&1 || true
    restore_qdisc_experiment >/dev/null 2>&1 || true
  fi
  exit 130
}
write_config() {
  local tmp i; tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
  chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! { printf '%s\n' "$MARKER"; printf '# role=%s bandwidth=%sMbit rtt=%sms generated=%s\n' "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; for i in "${!KEYS[@]}"; do printf '%s = %s\n' "${KEYS[$i]}" "${VALUES[$i]}"; done; printf '# vps-tcp-safe-tuner-end\n'; } >"$tmp"; then
    rm -f "$tmp"; return 1
  fi
  tail -n 1 "$tmp" | grep -Fqx '# vps-tcp-safe-tuner-end' || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CONFIG_FILE"
}
restore_snapshot_values() {
  local key value failed=0; [[ -f $SNAPSHOT_FILE ]] || return 0
  while IFS=$'\t' read -r key value; do
    [[ -z $key ]] && continue
    if ! sysctl_exists "$key" || ! sysctl -q -w "$key=$value"; then
      warn "恢复 $key 失败。"
      failed=1
    fi
  done <"$SNAPSHOT_FILE"
  return "$failed"
}
restore_legacy_core_defaults() {
  # v3.6.0 曾误把 TCP 初始值同时写入全局 socket 默认值。TCP 实际由
  # tcp_rmem/tcp_wmem 控制；升级时只在确认是本工具旧配置后恢复这两项。
  local key saved
  [[ -f $CONFIG_FILE && -f $SNAPSHOT_FILE ]] || return 0
  for key in net.core.rmem_default net.core.wmem_default; do
    grep -Fqx "$key = 1048576" "$CONFIG_FILE" || continue
    saved=$(awk -F'\t' -v wanted="$key" '$1 == wanted { print $2; exit }' "$SNAPSHOT_FILE")
    [[ -n $saved ]] || continue
    sysctl -q -w "$key=$saved" || return 1
    say "已恢复不再管理的 $key。"
  done
}
apply_built_settings() {
  local index current expected
  APPLIED_CHANGED_COUNT=0; APPLIED_UNCHANGED_COUNT=0
  for index in "${!KEYS[@]}"; do
    current=$(normalize_sysctl_value "$(sysctl_value "${KEYS[$index]}")")
    expected=$(normalize_sysctl_value "${VALUES[$index]}")
    if [[ $current == "$expected" ]]; then APPLIED_UNCHANGED_COUNT=$(( APPLIED_UNCHANGED_COUNT + 1 ))
    else APPLIED_CHANGED_COUNT=$(( APPLIED_CHANGED_COUNT + 1 ))
    fi
    sysctl -q -w "${KEYS[$index]}=${VALUES[$index]}" || return 1
  done
}
verify_built_settings() {
  local index current expected failed=0
  for index in "${!KEYS[@]}"; do
    current=$(normalize_sysctl_value "$(sysctl_value "${KEYS[$index]}")")
    expected=$(normalize_sysctl_value "${VALUES[$index]}")
    if [[ $current != "$expected" ]]; then
      warn "参数读回不一致：${KEYS[$index]}，期望 '$expected'，实际 '${current:-<空>}'。"
      failed=1
    fi
  done
  return "$failed"
}
load_and_verify_config() {
  sysctl -p "$CONFIG_FILE" >/dev/null || return 1
  verify_built_settings
}
verify_managed_config_live() {
  local raw line key expected current failed=0 checked=0
  [[ -f $CONFIG_FILE ]] || return 1
  while IFS= read -r raw || [[ -n $raw ]]; do
    line=${raw%%#*}; [[ $line == *=* ]] || continue
    key=$(normalize_sysctl_value "${line%%=*}")
    expected=$(normalize_sysctl_value "${line#*=}")
    current=$(normalize_sysctl_value "$(sysctl_value "$key")")
    checked=$(( checked + 1 ))
    if [[ $current != "$expected" ]]; then
      warn "运行值漂移：$key，配置 '$expected'，实际 '${current:-<空>}'。"
      failed=1
    fi
  done <"$CONFIG_FILE"
  (( checked > 0 )) || return 1
  return "$failed"
}
apply_tuning() {
  TUNING_APPLIED=0
  (( QDISC_EXPERIMENT == 0 || DEFER_PERSIST == 1 )) || fail '--experiment-qdisc 只能配合 auto/deep 使用，不能配合 apply。'
  require_root; require_linux; require_command sysctl; require_command ip; require_command tc; lock; validate_common
  [[ ! -e $TRANSACTION_FILE && ! -e $CONFIG_TRANSACTION_FILE && ! -e $CONFIG_TRANSACTION_ABSENT ]] || fail '检测到未完成事务；请先执行 rollback 或检查事务快照。'
  derive_network_facts; build_settings
  report_sysctl_conflicts "${KEYS[@]}" || fail '存在未处理的 sysctl 配置冲突，未修改系统。'
  show_plan
  (( DRY_RUN )) && { ok '预览完成，未修改系统。'; return 0; }
  if (( QDISC_EXPERIMENT )); then
    confirm '将启用内核已有的 BBR、临时应用候选 sysctl，并在保存精确快照后进行缓冲区及活动 FQ 队列 A/B 实验。继续吗？' || { say '已取消。'; return 0; }
  else
    confirm '将自动启用内核已有的 BBR（如尚未加载）、应用 FQ 活动队列、写入自适应 TCP 参数，并保存可精确回滚快照。继续吗？' || { say '已取消。'; return 0; }
  fi
  ensure_bbr
  snapshot_if_needed
  snapshot_transaction
  snapshot_config_transaction
  if ! restore_legacy_core_defaults; then
    warn '旧版全局 socket 默认值恢复失败，正在恢复本次应用前参数。'
    abort_transaction || fail '调优失败，且部分参数未能恢复；事务快照已保留。'
    fail '调优失败，已恢复本次应用前参数。'
  fi
  if ! apply_built_settings; then
    warn '候选 sysctl 应用失败，正在恢复本次应用前参数。'
    abort_transaction || fail '调优失败，且部分参数未能恢复；事务快照已保留。'
    fail '调优失败，已恢复本次应用前参数。'
  fi
  if ! verify_built_settings; then
    warn '候选 sysctl 写入后读回不一致，正在恢复本次应用前参数。'
    abort_transaction || fail '读回验证失败，且部分参数未能恢复；事务快照已保留。'
    fail '读回验证失败，已恢复本次应用前参数。'
  fi
  if (( QDISC_EXPERIMENT == 0 )) && ! apply_managed_fq; then
    warn '活动 FQ 应用失败，正在恢复本次应用前参数。'
    restore_qdisc_experiment >/dev/null 2>&1 || true
    abort_transaction || fail '活动 FQ 应用失败，且部分参数未能恢复；事务快照已保留。'
    fail '活动 FQ 应用失败，已恢复本次应用前参数。'
  fi
  if (( DEFER_PERSIST )); then
    TUNING_APPLIED=1; ok "已临时应用 ${#KEYS[@]} 项候选 TCP 设置及可恢复的活动 FQ，复测通过后才会持久化。"
  else
    if ! persist_qdisc_tune_state || ! write_facts || ! write_config || ! load_and_verify_config; then
      warn '持久化文件写入失败，正在恢复本次应用前参数。'
      restore_qdisc_experiment || warn '活动 qdisc 未能自动恢复；队列快照已保留。'
      abort_transaction || fail '持久化失败，且部分参数未能恢复；事务快照已保留。'
      fail '持久化失败，已恢复本次应用前参数。'
    fi
    discard_transaction; TUNING_APPLIED=1
    write_runtime_service || warn '网络恢复服务安装失败；当前配置有效，重启恢复尚未完成。'
    ok "已写入并逐项读回验证 ${#KEYS[@]} 项 TCP 设置：实际改变 ${APPLIED_CHANGED_COUNT} 项，原本一致 ${APPLIED_UNCHANGED_COUNT} 项。"
  fi
}
search_buffer_candidates() {
  local saved_override=$BUFFER_MULTIPLIER_OVERRIDE saved_rounds=$ROUNDS candidate candidate_rate candidate_retrans candidate_reverse_rate candidate_reverse_retrans candidate_score
  local reference_rate=${MEASURE_RATE:-0} reference_retrans=${MEASURE_RETRANS_PER_GIB:-0}
  local reference_reverse_rate=${MEASURE_REVERSE_RATE:-0} reference_reverse_retrans=${MEASURE_REVERSE_RETRANS_PER_GIB:-0} candidate_clean
  local best_multiplier='' best_rate=0 best_reverse_rate=0 best_retrans=0 best_reverse_retrans=0 best_score=0 candidate_rounds=2 search_tests
  local -a candidates=(1 2 3)
  (( NOISY_LINK == 0 )) || candidate_rounds=5
  search_tests=$(( 3 * candidate_rounds ))
  (( BIDIRECTIONAL == 0 )) || search_tests=$(( search_tests * 2 ))
  guard_test_traffic 'BDP 缓冲区搜索' "$BANDWIDTH_MBIT" "$search_tests" || { warn '已跳过高流量缓冲区搜索，保留默认 2× BDP 候选。'; return 0; }
  say '开始 BDP 缓冲区 A/B 搜索：分别测试 1×、2×、3× BDP 上限。'
  say "每个候选使用 ${candidate_rounds} 轮测试；仅保留吞吐最高且重传不明显恶化的候选。"
  ROUNDS=$candidate_rounds
  for candidate in "${candidates[@]}"; do
    BUFFER_MULTIPLIER_OVERRIDE=$candidate
    build_settings
    if ! apply_built_settings; then
      warn "${candidate}× BDP 参数只应用了一部分，正在恢复整个实验。"
      abort_transaction || fail '缓冲区候选应用失败，且部分参数未能恢复；事务快照已保留。'
      fail '缓冲区候选应用失败，已恢复实验前参数。'
    fi
    if ! measure; then
      warn "${candidate}× BDP 的测量不足，已跳过该候选。"
      continue
    fi
    candidate_rate=$MEASURE_RATE; candidate_retrans=$MEASURE_RETRANS_PER_GIB
    candidate_reverse_rate=${MEASURE_REVERSE_RATE:-0}; candidate_reverse_retrans=${MEASURE_REVERSE_RETRANS_PER_GIB:-0}
    candidate_score=$candidate_rate; (( BIDIRECTIONAL == 0 )) || candidate_score=$(( candidate_score + candidate_reverse_rate ))
    say "${candidate}× BDP：出站/入站 ${candidate_rate}/${candidate_reverse_rate} Mbit；重传 ${candidate_retrans}/${candidate_reverse_retrans} 次/GiB。"
    candidate_clean=1
    if is_material_regression "$reference_rate" "$reference_retrans" "$candidate_rate" "$candidate_retrans" '缓冲区出站'; then candidate_clean=0; fi
    candidate_retrans_is_acceptable "$reference_retrans" "$candidate_retrans" || candidate_clean=0
    if (( BIDIRECTIONAL )); then
      if is_material_regression "$reference_reverse_rate" "$reference_reverse_retrans" "$candidate_reverse_rate" "$candidate_reverse_retrans" '缓冲区入站'; then candidate_clean=0; fi
      candidate_retrans_is_acceptable "$reference_reverse_retrans" "$candidate_reverse_retrans" || candidate_clean=0
    fi
    if (( candidate_clean && candidate_score > best_score )); then
      best_multiplier=$candidate; best_rate=$candidate_rate; best_reverse_rate=$candidate_reverse_rate
      best_retrans=$candidate_retrans; best_reverse_retrans=$candidate_reverse_retrans; best_score=$candidate_score
    fi
  done
  ROUNDS=$saved_rounds
  if [[ -z $best_multiplier ]]; then
    BUFFER_MULTIPLIER_OVERRIDE=$saved_override
    build_settings
    apply_built_settings || { abort_transaction || fail '所有缓冲区候选均失败，且部分参数未能恢复；事务快照已保留。'; fail '所有缓冲区候选均失败，已恢复本次应用前参数。'; }
    warn '没有相对基线可接受的缓冲区候选，已恢复搜索前配置。'
    return 0
  fi
  BUFFER_MULTIPLIER_OVERRIDE=$best_multiplier
  build_settings
  apply_built_settings || { abort_transaction || fail '最佳缓冲区候选应用失败，且部分参数未能恢复；事务快照已保留。'; fail '最佳缓冲区候选应用失败，已恢复本次应用前参数。'; }
  say "已选择 ${best_multiplier}× BDP 缓冲区：出站/入站 ${best_rate}/${best_reverse_rate}Mbit，重传 ${best_retrans}/${best_reverse_retrans} 次/GiB。"
}

qdisc_leaf_is_restorable() { case "$1" in fq|fq_codel|pfifo_fast|pfifo|bfifo) return 0 ;; *) return 1 ;; esac; }
qdisc_is_restorable() { case "$1" in fq|fq_codel|pfifo_fast|pfifo|bfifo|mq) return 0 ;; *) return 1 ;; esac; }
qdisc_snapshot_mq() {
  local iface=$1 snapshot_file=$2 line kind parent spec found=0
  : >"$snapshot_file"; chmod 600 "$snapshot_file"
  while IFS= read -r line; do
    [[ $line == qdisc\ * && $line == *' parent '* ]] || continue
    kind=$(awk '{print $2}' <<<"$line")
    parent=$(awk '{for (i = 1; i <= NF; i += 1) if ($i == "parent") {print $(i + 1); exit}}' <<<"$line")
    qdisc_leaf_is_restorable "$kind" || return 1
    [[ $parent =~ ^(:|[0-9]+:)[1-9][0-9]*$ ]] || return 1
    spec=$(awk -v p="$parent" '{for (i = 1; i <= NF; i += 1) if ($i == "parent" && $(i + 1) == p) {for (j = i + 2; j <= NF; j += 1) printf "%s%s", (j == i + 2 ? "" : " "), $j; exit}}' <<<"$line")
    printf '%s\t%s\t%s\n' "$kind" "$parent" "$spec" >>"$snapshot_file"
    found=1
  done < <(tc qdisc show dev "$iface" 2>/dev/null)
  (( found ))
}
qdisc_snapshot() {
  local iface=$1 snapshot_file=${2:-} line kind spec
  line=$(tc qdisc show dev "$iface" 2>/dev/null | awk '$1 == "qdisc" {for (i = 1; i <= NF; i += 1) if ($i == "root") {print; exit}}')
  [[ -n $line ]] || return 1
  kind=$(awk '{print $2}' <<<"$line")
  if [[ $kind == mq ]]; then
    [[ -n $snapshot_file ]] || return 1
    qdisc_snapshot_mq "$iface" "$snapshot_file" || return 1
    printf 'mq\t%s' "$snapshot_file"
    return 0
  fi
  qdisc_leaf_is_restorable "$kind" || return 1
  # 保存 tc 输出中的根队列参数。仅对可无损重建的常见根队列开放整形。
  spec=$(sed -E 's/^qdisc [^ ]+ [^ ]+ root( refcnt [0-9]+)?[ ]*//' <<<"$line")
  printf '%s\t%s' "$kind" "$spec"
}
normalize_qdisc_spec() {
  awk '{
    previous = ""
    for (i = 1; i <= NF; i += 1) {
      token = $i
      if ((previous == "limit" || previous == "flow_limit") && token ~ /^[0-9]+p$/) sub(/p$/, "", token)
      printf "%s%s", (i == 1 ? "" : " "), token
      previous = $i
    }
  }' <<<"$1"
}
restore_mq_root_qdisc() {
  local iface=$1 snapshot_file=$2 kind parent spec minor
  local -a arguments=()
  [[ -f $snapshot_file ]] || return 1
  tc qdisc replace dev "$iface" root handle 1: mq || return 1
  while IFS=$'\t' read -r kind parent spec; do
    qdisc_leaf_is_restorable "$kind" || return 1
    [[ $parent =~ ^(:|[0-9]+:)[1-9][0-9]*$ ]] || return 1
    minor=${parent##*:}
    arguments=()
    if [[ -n $spec ]]; then
      spec=$(normalize_qdisc_spec "$spec")
      local IFS=' '
      read -r -a arguments <<<"$spec"
    fi
    tc qdisc replace dev "$iface" parent "1:$minor" "$kind" "${arguments[@]}" || return 1
  done <"$snapshot_file"
}
restore_root_qdisc() {
  local iface=$1 kind=$2 spec=$3
  local -a arguments=()
  qdisc_is_restorable "$kind" || return 1
  [[ $kind != mq ]] || { restore_mq_root_qdisc "$iface" "$spec"; return; }
  if [[ -n $spec ]]; then
    spec=$(normalize_qdisc_spec "$spec")
    local IFS=' '
    read -r -a arguments <<<"$spec"
  fi
  tc qdisc replace dev "$iface" root "$kind" "${arguments[@]}"
}
remove_qdisc_snapshot() {
  [[ ${1:-} == "$STATE_DIR"/qdisc-before-shape.* || ${1:-} == "$STATE_DIR"/qdisc-before-fq.* || ${1:-} == "$STATE_DIR"/qdisc-scan.* || ${1:-} == "$STATE_DIR"/qdisc-lab.* ]] && rm -f -- "$1"
  return 0
}
active_qdisc_is_fq() {
  local iface=$1 output root
  output=$(tc qdisc show dev "$iface" 2>/dev/null) || return 1
  root=$(awk '$1 == "qdisc" {for (i = 1; i <= NF; i += 1) if ($i == "root") {print $2; exit}}' <<<"$output")
  [[ $root == fq ]] && return 0
  [[ $root == mq ]] || return 1
  awk '
    $1 == "qdisc" && $0 ~ / parent / {leaves += 1; if ($2 != "fq") bad = 1}
    END {exit !(leaves > 0 && bad == 0)}
  ' <<<"$output"
}
apply_fq_candidate() {
  local iface=$1 original_kind=$2 snapshot_file=$3 kind parent minor found=0
  if [[ $original_kind != mq ]]; then
    tc qdisc replace dev "$iface" root fq
    return
  fi
  [[ -f $snapshot_file ]] || return 1
  tc qdisc replace dev "$iface" root handle 1: mq || return 1
  while IFS=$'\t' read -r kind parent _; do
    qdisc_leaf_is_restorable "$kind" || return 1
    [[ $parent =~ ^(:|[0-9]+:)[1-9][0-9]*$ ]] || return 1
    minor=${parent##*:}
    tc qdisc replace dev "$iface" parent "1:$minor" fq || return 1
    found=1
  done <"$snapshot_file"
  (( found ))
}
qdisc_candidate_is_better() {
  local base_rate=$1 base_retrans=$2 base_reverse_rate=$3 base_reverse_retrans=$4
  local candidate_rate=$5 candidate_retrans=$6 candidate_reverse_rate=$7 candidate_reverse_retrans=$8
  local base_total candidate_total required_gain=105
  (( NOISY_LINK == 0 )) || required_gain=120
  is_material_regression "$base_rate" "$base_retrans" "$candidate_rate" "$candidate_retrans" 'FQ 出站' && return 1
  (( candidate_rate * 100 >= base_rate * 95 )) || return 1
  base_total=$base_rate; candidate_total=$candidate_rate
  if (( BIDIRECTIONAL )); then
    is_material_regression "$base_reverse_rate" "$base_reverse_retrans" "$candidate_reverse_rate" "$candidate_reverse_retrans" 'FQ 入站' && return 1
    (( candidate_reverse_rate * 100 >= base_reverse_rate * 95 )) || return 1
    base_total=$(( base_total + base_reverse_rate )); candidate_total=$(( candidate_total + candidate_reverse_rate ))
  fi
  (( candidate_total * 100 >= base_total * required_gain ))
}
clear_qdisc_experiment_globals() {
  QDISC_SELECTED_FQ=0; QDISC_CHANGED=0; QDISC_ORIGINAL_IFACE=''; QDISC_ORIGINAL_KIND=''; QDISC_ORIGINAL_SPEC=''; QDISC_BACKUP_FILE=''
}
abort_after_qdisc_restore_failure() {
  local message=$1
  warn '活动 qdisc 恢复失败，正在至少恢复本次实验前的 sysctl。'
  if abort_transaction; then warn 'sysctl 已恢复；活动 qdisc 仍需人工处理。'
  else warn "部分 sysctl 也未能恢复；事务快照仍保留：$TRANSACTION_FILE"; fi
  fail "$message。队列快照仍保留；可先执行：tc qdisc replace dev $QDISC_ORIGINAL_IFACE root $QDISC_ORIGINAL_KIND"
}
restore_qdisc_experiment() {
  (( QDISC_CHANGED )) || return 0
  restore_root_qdisc "$QDISC_ORIGINAL_IFACE" "$QDISC_ORIGINAL_KIND" "$QDISC_ORIGINAL_SPEC" || return 1
  rm -f "$QDISC_TUNE_STATE"
  remove_qdisc_snapshot "$QDISC_BACKUP_FILE"
  clear_qdisc_experiment_globals
}
persist_qdisc_tune_state() {
  (( QDISC_SELECTED_FQ )) || return 0
  [[ ! -e $QDISC_TUNE_STATE ]] || return 0
  local tmp
  tmp=$(mktemp "$STATE_DIR/qdisc-tune.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  printf '%s\t%s\t%s\n' "$QDISC_ORIGINAL_IFACE" "$QDISC_ORIGINAL_KIND" "$QDISC_ORIGINAL_SPEC" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$QDISC_TUNE_STATE"
}
apply_managed_fq() {
  local iface snapshot managed_kind managed_spec
  if [[ -f $QDISC_TUNE_STATE ]]; then
    IFS=$'\t' read -r iface managed_kind managed_spec <"$QDISC_TUNE_STATE"
    validate_iface "$iface"; qdisc_is_restorable "$managed_kind" || return 1
    if ! active_qdisc_is_fq "$iface"; then
      if ! apply_fq_candidate "$iface" "$managed_kind" "$managed_spec"; then
        restore_root_qdisc "$iface" "$managed_kind" "$managed_spec" >/dev/null 2>&1 || true
        warn '已有 FQ 管理状态，但本次无法重建活动 FQ。'
        return 1
      fi
      ok "已根据现有回滚快照重建 $iface 的活动 FQ。"
    fi
    QDISC_SELECTED_FQ=1
    say '活动 FQ 已由本工具管理，本次保持现状。'
    return 0
  fi
  iface=$(default_interface); [[ -n $iface ]] || { warn '未检测到默认出口网卡，无法应用活动 FQ。'; return 1; }
  validate_iface "$iface"
  if active_qdisc_is_fq "$iface"; then
    say '当前活动队列已是 FQ；保持用户现有队列，不接管其回滚。'
    return 0
  fi
  install -d -m 700 "$STATE_DIR"
  QDISC_BACKUP_FILE=$(mktemp "$STATE_DIR/qdisc-before-fq.XXXXXX")
  snapshot=$(qdisc_snapshot "$iface" "$QDISC_BACKUP_FILE") || {
    rm -f -- "$QDISC_BACKUP_FILE"; QDISC_BACKUP_FILE=''
    warn '当前活动 qdisc 无法精确恢复，为避免破坏网络已拒绝切换。'; return 1;
  }
  IFS=$'\t' read -r QDISC_ORIGINAL_KIND QDISC_ORIGINAL_SPEC <<<"$snapshot"
  QDISC_ORIGINAL_IFACE=$iface
  if [[ $QDISC_ORIGINAL_KIND != mq ]]; then rm -f -- "$QDISC_BACKUP_FILE"; QDISC_BACKUP_FILE=''; fi
  if ! apply_fq_candidate "$iface" "$QDISC_ORIGINAL_KIND" "$QDISC_ORIGINAL_SPEC"; then
    restore_root_qdisc "$iface" "$QDISC_ORIGINAL_KIND" "$QDISC_ORIGINAL_SPEC" >/dev/null 2>&1 ||
      abort_after_qdisc_restore_failure 'FQ 应用失败，且原活动 qdisc 未能自动恢复'
    remove_qdisc_snapshot "$QDISC_BACKUP_FILE"; clear_qdisc_experiment_globals
    return 1
  fi
  QDISC_CHANGED=1; QDISC_SELECTED_FQ=1
  ok "已将 $iface 的活动队列从 $QDISC_ORIGINAL_KIND 切换为 FQ；原队列已保存，可精确回滚。"
}
restore_managed_qdisc_tune() {
  local iface kind spec
  [[ -f $QDISC_TUNE_STATE ]] || return 0
  IFS=$'\t' read -r iface kind spec <"$QDISC_TUNE_STATE"
  validate_iface "$iface"; qdisc_is_restorable "$kind" || return 1
  restore_root_qdisc "$iface" "$kind" "$spec" || return 1
  remove_qdisc_snapshot "$spec"
  rm -f "$QDISC_TUNE_STATE"
  clear_qdisc_experiment_globals
}
search_qdisc_candidate() {
  local iface snapshot saved_rounds candidate_rounds=2 qdisc_tests gain_percent=5
  local base_rate base_retrans base_reverse_rate base_reverse_retrans
  local candidate_rate candidate_retrans candidate_reverse_rate candidate_reverse_retrans
  if [[ -f $QDISC_TUNE_STATE ]]; then
    QDISC_SELECTED_FQ=1
    set_setting_value net.core.default_qdisc fq || return 1
    say '活动 FQ 已由此前深度实验保留，本次不重复替换队列。'
    return 0
  fi
  if (( NOISY_LINK )); then candidate_rounds=5; gain_percent=20; fi
  qdisc_tests=$(( 2 * candidate_rounds ))
  (( BIDIRECTIONAL == 0 )) || qdisc_tests=$(( qdisc_tests * 2 ))
  guard_test_traffic '活动 qdisc A/B 实验' "$BANDWIDTH_MBIT" "$qdisc_tests" || {
    warn '已跳过高流量 FQ 实验；此前 TCP 候选仍会接受最终复测。'; drop_setting net.core.default_qdisc; return 0;
  }
  iface=$(default_interface); [[ -n $iface ]] || { warn '未检测到默认出口网卡，已跳过 FQ 实验。'; drop_setting net.core.default_qdisc; return 0; }
  validate_iface "$iface"
  if active_qdisc_is_fq "$iface"; then
    say '当前活动队列已经是 FQ；保持用户现有队列，不接管其持久化。'
    drop_setting net.core.default_qdisc
    return 0
  fi
  install -d -m 700 "$STATE_DIR"
  QDISC_BACKUP_FILE=$(mktemp "$STATE_DIR/qdisc-lab.XXXXXX")
  snapshot=$(qdisc_snapshot "$iface" "$QDISC_BACKUP_FILE") || {
    rm -f -- "$QDISC_BACKUP_FILE"; QDISC_BACKUP_FILE=''; drop_setting net.core.default_qdisc
    warn '当前活动 qdisc 无法精确恢复，已安全跳过 FQ 实验。'; return 0;
  }
  IFS=$'\t' read -r QDISC_ORIGINAL_KIND QDISC_ORIGINAL_SPEC <<<"$snapshot"
  QDISC_ORIGINAL_IFACE=$iface
  if [[ $QDISC_ORIGINAL_KIND != mq ]]; then rm -f -- "$QDISC_BACKUP_FILE"; QDISC_BACKUP_FILE=''; fi
  saved_rounds=$ROUNDS; ROUNDS=$candidate_rounds
  say "深度实验：先测当前活动队列 $QDISC_ORIGINAL_KIND，再临时切换 FQ；每个候选测试 ${candidate_rounds} 轮。"
  if ! measure; then
    ROUNDS=$saved_rounds; remove_qdisc_snapshot "$QDISC_BACKUP_FILE"; clear_qdisc_experiment_globals
    drop_setting net.core.default_qdisc; warn '当前队列候选测量不稳定，已跳过 FQ 实验。'; return 0
  fi
  base_rate=$MEASURE_RATE; base_retrans=$MEASURE_RETRANS_PER_GIB
  base_reverse_rate=${MEASURE_REVERSE_RATE:-0}; base_reverse_retrans=${MEASURE_REVERSE_RETRANS_PER_GIB:-0}
  if ! apply_fq_candidate "$iface" "$QDISC_ORIGINAL_KIND" "$QDISC_ORIGINAL_SPEC"; then
    ROUNDS=$saved_rounds
    restore_root_qdisc "$iface" "$QDISC_ORIGINAL_KIND" "$QDISC_ORIGINAL_SPEC" >/dev/null 2>&1 || abort_after_qdisc_restore_failure 'FQ 候选应用失败，且原活动 qdisc 未能自动恢复'
    remove_qdisc_snapshot "$QDISC_BACKUP_FILE"; clear_qdisc_experiment_globals; drop_setting net.core.default_qdisc
    warn 'FQ 候选无法应用，已恢复原活动 qdisc。'; return 0
  fi
  QDISC_CHANGED=1
  if ! measure; then
    ROUNDS=$saved_rounds
    restore_qdisc_experiment || abort_after_qdisc_restore_failure 'FQ 候选测量失败，且原活动 qdisc 未能自动恢复'
    drop_setting net.core.default_qdisc; warn 'FQ 候选测量不稳定，已恢复原活动 qdisc。'; return 0
  fi
  candidate_rate=$MEASURE_RATE; candidate_retrans=$MEASURE_RETRANS_PER_GIB
  candidate_reverse_rate=${MEASURE_REVERSE_RATE:-0}; candidate_reverse_retrans=${MEASURE_REVERSE_RETRANS_PER_GIB:-0}
  ROUNDS=$saved_rounds
  say "队列对比：原队列出站/入站 ${base_rate}/${base_reverse_rate} Mbit；FQ ${candidate_rate}/${candidate_reverse_rate} Mbit。"
  if qdisc_candidate_is_better "$base_rate" "$base_retrans" "$base_reverse_rate" "$base_reverse_retrans" "$candidate_rate" "$candidate_retrans" "$candidate_reverse_rate" "$candidate_reverse_retrans"; then
    if ! set_setting_value net.core.default_qdisc fq || ! sysctl -q -w net.core.default_qdisc=fq; then
      restore_qdisc_experiment || abort_after_qdisc_restore_failure 'FQ 持久化失败，且原活动 qdisc 未能自动恢复'
      drop_setting net.core.default_qdisc; warn 'FQ 无法写入持久配置，已恢复原活动 qdisc。'; return 0
    fi
    QDISC_SELECTED_FQ=1
    ok "FQ 双向综合吞吐至少提升 ${gain_percent}%，且单方向下降未超过 5%；已选择 FQ 候选。"
    return 0
  fi
  restore_qdisc_experiment || abort_after_qdisc_restore_failure 'FQ 未胜出，且原活动 qdisc 未能自动恢复'
  drop_setting net.core.default_qdisc
  say 'FQ 未达到双向择优门槛，已恢复原活动 qdisc。'
}
managed_file_or_absent() {
  local path=$1 marker=$2
  if [[ -e $path || -L $path ]]; then
    [[ -f $path && ! -L $path ]] || fail "拒绝覆盖非普通文件：$path"
    grep -Fqx "$marker" "$path" || fail "拒绝覆盖不归本工具管理的文件：$path"
  fi
}
remove_managed_file() {
  local path=$1 marker=$2
  [[ -e $path || -L $path ]] || return 0
  [[ -f $path && ! -L $path ]] || fail "拒绝删除非普通文件：$path"
  grep -Fqx "$marker" "$path" || fail "拒绝删除不归本工具管理的文件：$path"
  rm -f -- "$path"
}
write_shape_service() {
  local iface=$1 rate=$2 original=$3 original_spec=$4 script_tmp unit_tmp state_tmp
  validate_iface "$iface"
  is_positive_integer "$rate" && (( rate <= 100000 )) || fail '拒绝写入无效整形速率。'
  managed_file_or_absent "$SHAPE_SCRIPT" "$SHAPE_SCRIPT_MARKER"
  managed_file_or_absent "$SHAPE_UNIT" "$SHAPE_UNIT_MARKER"
  install -d -m 700 "$STATE_DIR" || return 1
  script_tmp=$(mktemp "${SHAPE_SCRIPT}.XXXXXX") || return 1
  unit_tmp=$(mktemp "${SHAPE_UNIT}.XXXXXX") || { rm -f "$script_tmp"; return 1; }
  state_tmp=$(mktemp "$STATE_DIR/qdisc.XXXXXX") || { rm -f "$script_tmp" "$unit_tmp"; return 1; }
  if ! cat >"$script_tmp" <<EOF
#!/usr/bin/env bash
$SHAPE_SCRIPT_MARKER
set -Eeuo pipefail
tc qdisc replace dev '$iface' root handle 1: htb default 10
tc class replace dev '$iface' parent 1: classid 1:10 htb rate ${rate}mbit ceil ${rate}mbit
tc qdisc replace dev '$iface' parent 1:10 handle 10: fq
EOF
  then
    rm -f "$script_tmp" "$unit_tmp" "$state_tmp"; return 1
  fi
  if ! cat >"$unit_tmp" <<EOF
$SHAPE_UNIT_MARKER
[Unit]
Description=VPS TCP Safe Tuner egress shaper
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$SHAPE_SCRIPT
RemainAfterExit=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_ADMIN
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
  then
    rm -f "$script_tmp" "$unit_tmp" "$state_tmp"; return 1
  fi
  if ! printf '%s\t%s\t%s\t%s\n' "$iface" "$rate" "$original" "$original_spec" >"$state_tmp" ||
     ! chmod 700 "$script_tmp" || ! chmod 644 "$unit_tmp" || ! chmod 600 "$state_tmp" ||
     ! mv -f "$script_tmp" "$SHAPE_SCRIPT" || ! mv -f "$unit_tmp" "$SHAPE_UNIT" ||
     ! mv -f "$state_tmp" "$SHAPE_STATE"; then
    rm -f "$script_tmp" "$unit_tmp" "$state_tmp"; return 1
  fi
  systemctl daemon-reload && systemctl enable vps-tcp-safe-tuner-qdisc.service >/dev/null
}
apply_shape() { validate_iface "$1"; tc qdisc replace dev "$1" root handle 1: htb default 10; tc class replace dev "$1" parent 1: classid 1:10 htb rate "${2}mbit" ceil "${2}mbit"; tc qdisc replace dev "$1" parent 1:10 handle 10: fq; }
shape() {
  require_root; require_linux; require_command tc; require_command systemctl; lock; validate_common; is_positive_integer "$SHAPE_RATE" || fail 'shape 需要 --shape-rate 正整数。'; (( SHAPE_RATE <= 100000 )) || fail '--shape-rate 不能超过 100000 Mbit/s。'
  local iface original original_spec snapshot qdisc_backup
  (( ENABLE_SHAPING )) || fail '整形必须显式加入 --enable-shaping。'
  iface=$(default_interface); [[ -n $iface ]] || fail '未检测到默认出口网卡。'
  validate_iface "$iface"
  [[ ! -e $SHAPE_STATE ]] || fail '已存在本工具整形状态；请先执行 unshape，避免覆盖原始 qdisc 快照。'
  install -d -m 700 "$STATE_DIR"; qdisc_backup=$(mktemp "$STATE_DIR/qdisc-before-shape.XXXXXX")
  snapshot=$(qdisc_snapshot "$iface" "$qdisc_backup") || { rm -f -- "$qdisc_backup"; fail '当前根 qdisc 无法精确重建；为避免破坏多队列或特殊配置，拒绝整形。'; }
  IFS=$'\t' read -r original original_spec <<<"$snapshot"
  [[ $original == mq ]] || rm -f -- "$qdisc_backup"
  line; warn "整形将暂时替换 $iface 的活动根 qdisc=$original，可能短暂影响连接。"; [[ $original == mq ]] && say '已保存 mq 的每个可恢复叶子 qdisc 参数。' || say "已保存根队列参数：${original_spec:-默认参数}"; say "目标速率：${SHAPE_RATE} Mbit/s；叶子队列：FQ；重启后由 systemd 恢复。"
  (( DRY_RUN )) && { remove_qdisc_snapshot "$qdisc_backup"; ok '整形预览完成，未修改系统。'; return 0; }; confirm '确认应用 HTB + FQ 出向整形吗？' || { remove_qdisc_snapshot "$qdisc_backup"; say '已取消。'; return 0; }
  if ! write_shape_service "$iface" "$SHAPE_RATE" "$original" "$original_spec"; then
    warn '持久化整形服务写入或启用失败，正在清理并恢复原 qdisc。'
    ASSUME_YES=1; unshape || true
    fail '整形持久化失败，未保留候选整形。'
  fi
  if ! apply_shape "$iface" "$SHAPE_RATE"; then
    warn '应用整形失败，正在移除本工具创建的持久化整形文件。'
    ASSUME_YES=1; unshape || true
    fail '整形失败，已尝试恢复根队列。'
  fi
  ok '出向整形已应用；请立即使用 verify 对比吞吐和重传。'
}
unshape() {
  require_root; require_linux; require_command tc; require_command systemctl; lock; [[ -f $SHAPE_STATE ]] || { say '未检测到本工具创建的整形。'; return 0; }
  local iface rate original original_spec; IFS=$'\t' read -r iface rate original original_spec <"$SHAPE_STATE"; qdisc_is_restorable "$original" || fail '整形状态损坏，拒绝猜测原始 qdisc。'
  validate_iface "$iface"; is_positive_integer "$rate" && (( rate <= 100000 )) || fail '整形状态中的速率无效，拒绝继续。'
  managed_file_or_absent "$SHAPE_SCRIPT" "$SHAPE_SCRIPT_MARKER"
  managed_file_or_absent "$SHAPE_UNIT" "$SHAPE_UNIT_MARKER"
  (( DRY_RUN )) && { say "将恢复 $iface 的根 qdisc 为 $original。"; return 0; }; confirm "移除 ${rate}Mbit 整形并恢复 $original 吗？" || { say '已取消。'; return 0; }
  systemctl disable --now vps-tcp-safe-tuner-qdisc.service >/dev/null 2>&1 || true
  remove_managed_file "$SHAPE_UNIT" "$SHAPE_UNIT_MARKER"
  remove_managed_file "$SHAPE_SCRIPT" "$SHAPE_SCRIPT_MARKER"
  systemctl daemon-reload
  restore_root_qdisc "$iface" "$original" "$original_spec" || fail '恢复根 qdisc 参数失败；整形状态文件已保留，可检查后重试。'
  remove_qdisc_snapshot "$original_spec"; rm -f "$SHAPE_STATE"; ok '已移除本工具整形并恢复根 qdisc 参数。'
}
policer_candidate_is_clean() {
  local rate=$1 retrans_per_gib=$2 target_rate=$3 baseline_retrans_per_gib=$4 allowed_retrans
  allowed_retrans=$(( baseline_retrans_per_gib * 2 + RETRANS_PER_GIB_MARGIN ))
  (( allowed_retrans < RETRANS_PER_GIB_HARD_LIMIT )) && allowed_retrans=$RETRANS_PER_GIB_HARD_LIMIT
  (( retrans_per_gib <= allowed_retrans && rate * 100 >= target_rate * 90 ))
}
probe_shaper_candidate() {
  local iface=$1 original=$2 original_spec=$3 candidate_rate=$4 baseline_retrans_per_gib=$5
  apply_shape "$iface" "$candidate_rate" || return 2
  if ! measure; then
    restore_root_qdisc "$iface" "$original" "$original_spec" || return 2
    return 2
  fi
  restore_root_qdisc "$iface" "$original" "$original_spec" || return 2
  say "扫描 ${candidate_rate}Mbit：中位吞吐 ${MEASURE_RATE}Mbit，重传 ${MEASURE_RETRANS_PER_GIB} 次/GiB。"
  policer_candidate_is_clean "$MEASURE_RATE" "$MEASURE_RETRANS_PER_GIB" "$candidate_rate" "$baseline_retrans_per_gib"
}
probe_adaptive_shaper_candidate() {
  local iface=$1 original=$2 original_spec=$3 candidate_rate=$4 baseline_retrans_per_gib=$5
  local saved_rounds=$ROUNDS probe_status
  ROUNDS=1
  if probe_shaper_candidate "$iface" "$original" "$original_spec" "$candidate_rate" "$baseline_retrans_per_gib"; then
    ROUNDS=$saved_rounds
    return 0
  else
    probe_status=$?
  fi
  if (( probe_status != 1 )); then
    ROUNDS=$saved_rounds
    return 2
  fi
  say "${candidate_rate}Mbit 首个样本疑似进入丢包区，改用 ${POLICER_ROUNDS} 轮复核，避免瞬时抖动误判拐点。"
  ROUNDS=$POLICER_ROUNDS
  if probe_shaper_candidate "$iface" "$original" "$original_spec" "$candidate_rate" "$baseline_retrans_per_gib"; then
    ROUNDS=$saved_rounds
    return 0
  else
    probe_status=$?
  fi
  ROUNDS=$saved_rounds
  return "$probe_status"
}
path_quality_check() {
  validate_peer; ensure_iperf3; require_command tc
  local iface original original_spec snapshot qdisc_backup target_rate
  local saved_rounds=$ROUNDS saved_bidirectional=$BIDIRECTIONAL saved_bandwidth=$BANDWIDTH_MBIT
  iface=$(default_interface); [[ -n $iface ]] || { warn '未检测到默认出口网卡，无法进行路径质量检测。'; return 1; }
  validate_iface "$iface"
  target_rate=$(( BANDWIDTH_MBIT * 40 / 100 )); (( target_rate < 1 )) && target_rate=1
  install -d -m 700 "$STATE_DIR"; qdisc_backup=$(mktemp "$STATE_DIR/qdisc-path-check.XXXXXX")
  snapshot=$(qdisc_snapshot "$iface" "$qdisc_backup") || { rm -f -- "$qdisc_backup"; warn '当前根 qdisc 无法精确重建，跳过路径质量检测。'; return 1; }
  IFS=$'\t' read -r original original_spec <<<"$snapshot"
  [[ $original == mq ]] || rm -f -- "$qdisc_backup"
  ROUNDS=$POLICER_ROUNDS; BIDIRECTIONAL=0; BANDWIDTH_MBIT=$target_rate
  trap 'restore_root_qdisc "$iface" "$original" "$original_spec" >/dev/null 2>&1 || true; remove_qdisc_snapshot "$qdisc_backup"; ROUNDS=$saved_rounds; BIDIRECTIONAL=$saved_bidirectional; BANDWIDTH_MBIT=$saved_bandwidth' EXIT
  trap 'exit 130' INT TERM HUP
  say "以套餐带宽的 40%（${target_rate}Mbit/s）临时应用 HTB+FQ，检测低于限速器拐点时的线路底噪。"
  if ! apply_shape "$iface" "$target_rate" || ! measure; then
    restore_root_qdisc "$iface" "$original" "$original_spec" >/dev/null 2>&1 || true
    remove_qdisc_snapshot "$qdisc_backup"; ROUNDS=$saved_rounds; BIDIRECTIONAL=$saved_bidirectional; BANDWIDTH_MBIT=$saved_bandwidth
    trap - EXIT INT TERM HUP
    warn '路径质量检测没有取得可靠样本；基础调优保留，后续扫描会自行判定。'
    return 1
  fi
  restore_root_qdisc "$iface" "$original" "$original_spec" || fail '路径质量检测后恢复根 qdisc 失败，请立即检查网络。'
  remove_qdisc_snapshot "$qdisc_backup"; ROUNDS=$saved_rounds; BIDIRECTIONAL=$saved_bidirectional; BANDWIDTH_MBIT=$saved_bandwidth
  trap - EXIT INT TERM HUP
  if (( MEASURE_RETRANS_PER_GIB <= RETRANS_PER_GIB_HARD_LIMIT )); then
    ok "40% 速率路径样本干净：${MEASURE_RATE}Mbit/s，重传 ${MEASURE_RETRANS_PER_GIB} 次/GiB。"
  else
    warn "40% 速率仍有较高重传（${MEASURE_RETRANS_PER_GIB} 次/GiB）；线路本身可能有损，后续拐点会保守判定。"
  fi
}
scan_shaper_candidate() {
  RECOMMENDED_SHAPE_RATE=''
  validate_peer; ensure_iperf3; require_command tc
  local nominal candidate best='' last_clean='' broke_at='' iface original original_spec snapshot saved_rounds saved_bidirectional baseline_retrans_per_gib qdisc_backup probe_status safe_rate refine_steps=0
  local -a coarse=(55 70 82 90 96 100 106 114 123 133 145)
  iface=$(default_interface); [[ -n $iface ]] || fail '未检测到默认出口网卡。'
  validate_iface "$iface"
  install -d -m 700 "$STATE_DIR"; qdisc_backup=$(mktemp "$STATE_DIR/qdisc-scan.XXXXXX")
  snapshot=$(qdisc_snapshot "$iface" "$qdisc_backup") || { rm -f -- "$qdisc_backup"; fail '当前根 qdisc 无法精确重建，拒绝扫描整形。'; }
  IFS=$'\t' read -r original original_spec <<<"$snapshot"
  [[ $original == mq ]] || rm -f -- "$qdisc_backup"
  nominal=${MEASURE_RATE:-$BANDWIDTH_MBIT}
  guard_test_traffic '限速器拐点扫描（自适应上限）' "$nominal" "$(( ${#coarse[@]} + 4 + POLICER_ROUNDS ))" || { warn '已跳过高流量限速器扫描；基础 TCP 调优不受影响。'; remove_qdisc_snapshot "$qdisc_backup"; return 0; }
  baseline_retrans_per_gib=${MEASURE_RETRANS_PER_GIB:-0}
  say "开始限速器拐点扫描：以 ${nominal}Mbit 全速基线从 55% 到 145% 自适应粗扫。"
  say "正常候选只测 1 轮；只有疑似丢包拐点才使用 ${POLICER_ROUNDS} 轮复核。"
  say '发现拐点后最多二分精扫 4 档；每轮临时 HTB+FQ 后都会恢复原 qdisc。'
  confirm "扫描会暂时替换 $iface 的根 qdisc，预计消耗较多流量。继续吗？" || { remove_qdisc_snapshot "$qdisc_backup"; say '已跳过扫描。'; return 0; }
  saved_rounds=$ROUNDS; saved_bidirectional=$BIDIRECTIONAL; BIDIRECTIONAL=0
  trap 'restore_root_qdisc "$iface" "$original" "$original_spec" >/dev/null 2>&1 || true; remove_qdisc_snapshot "$qdisc_backup"; ROUNDS=$saved_rounds; BIDIRECTIONAL=$saved_bidirectional' EXIT
  trap 'exit 130' INT TERM HUP
  for candidate in "${coarse[@]}"; do
    SHAPE_RATE=$(( nominal * candidate / 100 ))
    if probe_adaptive_shaper_candidate "$iface" "$original" "$original_spec" "$SHAPE_RATE" "$baseline_retrans_per_gib"; then
      last_clean=$SHAPE_RATE; best=$SHAPE_RATE
    else
      probe_status=$?
      (( probe_status == 1 )) || fail '扫描整形应用或恢复失败，已触发 qdisc 恢复保护。'
      broke_at=$SHAPE_RATE
      break
    fi
  done
  if [[ -n $last_clean && -n $broke_at ]]; then
    say "拐点区间：${last_clean} 到 ${broke_at} Mbit，开始二分精扫。"
    while (( broke_at - last_clean > 1 && refine_steps < 4 )); do
      refine_steps=$(( refine_steps + 1 ))
      candidate=$(( (last_clean + broke_at) / 2 ))
      if probe_adaptive_shaper_candidate "$iface" "$original" "$original_spec" "$candidate" "$baseline_retrans_per_gib"; then
        last_clean=$candidate; best=$candidate
      else
        probe_status=$?
        (( probe_status == 1 )) || fail '二分精扫应用或恢复失败，已触发 qdisc 恢复保护。'
        broke_at=$candidate
      fi
    done
  fi
  ROUNDS=$saved_rounds; BIDIRECTIONAL=$saved_bidirectional
  restore_root_qdisc "$iface" "$original" "$original_spec" || fail '扫描结束时恢复根 qdisc 参数失败，请立即检查网络状态。'
  trap - EXIT INT TERM HUP
  remove_qdisc_snapshot "$qdisc_backup"
  if [[ -n $best && -n $broke_at ]]; then
    safe_rate=$(( best * 97 / 100 )); (( safe_rate < 1 )) && safe_rate=1
    RECOMMENDED_SHAPE_RATE=$safe_rate
    say "建议整形速率：${safe_rate} Mbit/s（拐点前 ${best}Mbit 留出 3% 余量）。"
    say "请用 shape --shape-rate ${safe_rate} --enable-shaping 后再 verify。"
  else
    warn '扫描范围内没有确认的限速器拐点，不建议盲目整形。'
  fi
}
auto() {
  local baseline_rate baseline_retrans_per_gib baseline_reverse_rate baseline_reverse_retrans_per_gib
  local after_rate after_retrans_per_gib after_reverse_rate after_reverse_retrans_per_gib decision regressed=0 regression_reasons=''
  require_root; require_linux; validate_common
  trap abort_auto_on_signal INT TERM HUP
  say '阶段 1/3：记录调优前基线。'
  if ! measure; then
    fail '调优前基线不足，未改动系统。请稍后重试或指定可信 iperf3 对端。'
  fi
  baseline_rate=$MEASURE_RATE; baseline_retrans_per_gib=$MEASURE_RETRANS_PER_GIB
  baseline_reverse_rate=${MEASURE_REVERSE_RATE:-}; baseline_reverse_retrans_per_gib=${MEASURE_REVERSE_RETRANS_PER_GIB:-}
  NOISY_LINK=0
  if (( MEASURE_NOISY || MEASURE_REVERSE_NOISY )); then
    NOISY_LINK=1
    warn '已识别为噪声线路：后续缓冲区和 qdisc 候选自动提升为 5 轮，并要求 FQ 至少提升 20%，避免偶然波动被误判为优化。'
  fi
  BANDWIDTH_MBIT=$baseline_rate
  if (( BIDIRECTIONAL )) && (( baseline_reverse_rate > BANDWIDTH_MBIT )); then BANDWIDTH_MBIT=$baseline_reverse_rate; fi
  BUFFER_BANDWIDTH_MBIT=$(estimate_buffer_bandwidth "$BANDWIDTH_MBIT")
  say "自动实测容量为 ${BANDWIDTH_MBIT}Mbit/s；TCP 窗口按实测值的 ${AUTO_BUFFER_HEADROOM_PERCENT}% 向上取 ${BUFFER_BANDWIDTH_MBIT}Mbit/s 常见端口档位。该值只放宽自动调谐上限，不作为测速成绩或整形速率。"
  if [[ -z $RTT_MS ]]; then
    RTT_MS=$AUTO_TARGET_RTT_MS
    say "测速对端 RTT 为 ${MEASURE_RTT:-未取得}ms，仅用于测量质量；BDP 按出站/入站较大吞吐 ${BANDWIDTH_MBIT}Mbit/s 与跨境业务默认目标 RTT ${RTT_MS}ms 推导。"
  else
    say "BDP 使用出站/入站较大吞吐 ${BANDWIDTH_MBIT}Mbit/s 与你指定的业务目标 RTT ${RTT_MS}ms；测速对端 RTT 为 ${MEASURE_RTT:-未取得}ms。"
  fi
  derive_network_facts
  say '阶段 2/3：应用按基线推导的候选配置。'
  DEFER_PERSIST=1
  apply_tuning
  DEFER_PERSIST=0
  (( TUNING_APPLIED )) || { trap - INT TERM HUP; say '候选配置未应用，已结束实验。'; return 0; }
  if (( BUFFER_SEARCH )); then
    say '附加阶段：搜索当前线路更合适的 BDP 缓冲区倍率。'
    search_buffer_candidates
  fi
  if (( QDISC_EXPERIMENT )); then
    say '附加阶段：比较原活动队列与 FQ 候选。'
    search_qdisc_candidate
  fi
  say '阶段 3/3：使用同一对端、同一轮次复测。'
  if ! measure; then
    decision='rolled_back_unverified'
    write_experiment_report "$baseline_rate" "$baseline_retrans_per_gib" '' '' "$decision" "$baseline_reverse_rate" "$baseline_reverse_retrans_per_gib" '' ''
    warn "复测不足，候选参数不予保留。最后一次 iperf3 错误：${MEASURE_FAILURE:-未取得}"
    revert_auto_experiment
    trap - INT TERM HUP
    return 0
  fi
  after_rate=$MEASURE_RATE; after_retrans_per_gib=$MEASURE_RETRANS_PER_GIB
  after_reverse_rate=${MEASURE_REVERSE_RATE:-}; after_reverse_retrans_per_gib=${MEASURE_REVERSE_RETRANS_PER_GIB:-}
  decision='retained'
  if is_material_regression "$baseline_rate" "$baseline_retrans_per_gib" "$after_rate" "$after_retrans_per_gib" '出站'; then regressed=1; regression_reasons=$REGRESSION_REASON; fi
  if (( BIDIRECTIONAL )) && is_material_regression "$baseline_reverse_rate" "$baseline_reverse_retrans_per_gib" "$after_reverse_rate" "$after_reverse_retrans_per_gib" '入站'; then
    regressed=1; regression_reasons+="${regression_reasons:+；}$REGRESSION_REASON"
  fi
  if (( regressed )); then
    warn "候选配置未通过：$regression_reasons。"
    if (( KEEP_ON_REGRESSION )); then
      decision='retained_by_override'
      warn '复测出现明显退化，但你指定了 --keep-on-regression，配置将保留。'
    else
      decision='rolled_back_regression'
    fi
  fi
  write_experiment_report "$baseline_rate" "$baseline_retrans_per_gib" "$after_rate" "$after_retrans_per_gib" "$decision" "$baseline_reverse_rate" "$baseline_reverse_retrans_per_gib" "$after_reverse_rate" "$after_reverse_retrans_per_gib"
  if [[ $decision == rolled_back_regression ]]; then
    revert_auto_experiment
    trap - INT TERM HUP
    return 0
  fi
  if ! persist_qdisc_tune_state || ! write_facts || ! write_config || ! load_and_verify_config; then
    warn '复测通过，但持久化文件写入失败，正在恢复实验前参数。'
    revert_auto_experiment || fail '持久化失败，且部分参数或活动 qdisc 未能恢复；事务快照与队列快照均已保留。'
    fail '持久化失败，已恢复实验前参数。'
  fi
  discard_transaction
  trap - INT TERM HUP
  write_runtime_service || warn '网络恢复服务安装失败；当前 TCP 配置有效，重启后活动 FQ 尚未保证恢复。'
  ok '复测未出现明显退化，候选 TCP 配置已持久化并逐项读回验证。'
  if (( ENABLE_SHAPING )); then
    if [[ $MEASURE_RETRANS_PER_GIB == 0 ]]; then say '验证无重传，跳过限速器扫描。';
    else warn '已启用限速器候选扫描。扫描只给出建议，不会持久化整形。'; scan_shaper_candidate; fi
  fi
}
tune_shaper() {
  local base_rate base_retrans reverse_rate reverse_retrans iface snapshot kind spec backup saved_yes=$ASSUME_YES accepted=0
  [[ ! -f $SHAPE_STATE ]] || { warn '已有受管整形，跳过重复扫描。'; return 0; }
  (( WIZARD_MODE == 0 )) || say '[3/5] 限速器拐点扫描：先记录基础调优后的全速基线。'
  if ! measure; then warn '验证样本不足；已保留完成的基础调优，跳过整形。'; return 0; fi
  base_rate=$MEASURE_RATE; base_retrans=$MEASURE_RETRANS_PER_GIB
  reverse_rate=${MEASURE_REVERSE_RATE:-0}; reverse_retrans=${MEASURE_REVERSE_RETRANS_PER_GIB:-0}
  if (( base_retrans <= RETRANS_PER_GIB_HARD_LIMIT )); then
    say '全速基线重传未达到限速器扫描门槛，保持不整形。'
    (( WIZARD_MODE == 0 )) || { say '[4/5] 没有发现需要整形的证据。'; say '[5/5] 基础调优已保留；无需继续消耗扫描流量。'; }
    return 0
  fi
  scan_shaper_candidate
  if [[ -z $RECOMMENDED_SHAPE_RATE ]]; then
    (( WIZARD_MODE == 0 )) || { say '[4/5] 未找到可信拐点，不应用整形。'; say '[5/5] 已保留基础调优；全速基线没有证据支持额外限速。'; }
    return 0
  fi
  (( WIZARD_MODE == 0 )) || say "[4/5] 临时应用 ${RECOMMENDED_SHAPE_RATE}Mbit/s 候选整形。"
  iface=$(default_interface); backup=$(mktemp "$STATE_DIR/qdisc-lab.XXXXXX")
  snapshot=$(qdisc_snapshot "$iface" "$backup") || { rm -f "$backup"; return 1; }
  IFS=$'\t' read -r kind spec <<<"$snapshot"
  trap 'restore_root_qdisc "$iface" "$kind" "$spec" || true; remove_qdisc_snapshot "$backup"' EXIT
  trap 'exit 130' INT TERM HUP
  (( WIZARD_MODE == 0 )) || say '[5/5] 使用同一对端复测候选整形，只有吞吐/重传达标才持久化。'
  if apply_shape "$iface" "$RECOMMENDED_SHAPE_RATE" && measure; then
    if ! is_material_regression "$base_rate" "$base_retrans" "$MEASURE_RATE" "$MEASURE_RETRANS_PER_GIB" &&
       { (( BIDIRECTIONAL == 0 )) || ! is_material_regression "$reverse_rate" "$reverse_retrans" "$MEASURE_REVERSE_RATE" "$MEASURE_REVERSE_RETRANS_PER_GIB"; }; then
      if (( MEASURE_RATE * 100 >= base_rate * 105 )) ||
         (( MEASURE_RATE * 100 >= base_rate * 95 && MEASURE_RETRANS_PER_GIB * 2 <= base_retrans )); then accepted=1; fi
    fi
  fi
  restore_root_qdisc "$iface" "$kind" "$spec" || fail '候选整形验证后队列恢复失败；已保留恢复保护。'
  trap - EXIT INT TERM HUP
  remove_qdisc_snapshot "$backup"
  if (( accepted )); then
    SHAPE_RATE=$RECOMMENDED_SHAPE_RATE; ASSUME_YES=1
    shape
    ASSUME_YES=$saved_yes
    ok '候选整形已通过同对端复测并持久化：吞吐提高至少 5%，或吞吐保持 95% 且重传减少至少一半。'
  else say '候选整形未证实收益；保留基础调优及原队列，不持久化限速。'; fi
}
route_field() {
  awk -v key="$1" '{for(i=1;i<NF;i++)if($i==key){print $(i+1);exit}}' <<<"$2"
}
route_with_windows() {
  local route=$1 cw=$2 rw=$3 token skip=0
  local -a words=() clean=()
  # 只处理单一路径的 IPv4 默认路由，保留当前网关、metric、src 等其它属性。
  [[ $route == default\ * && $route != *$'\n'* && $route != *'nexthop '* && $route != *' encap '* ]] || return 1
  is_safe_iface "$(route_field dev "$route")" || return 1
  [[ $cw =~ ^[0-9]+$ && $rw =~ ^[0-9]+$ ]] || return 1
  IFS=' ' read -r -a words <<<"$route"
  for token in "${words[@]}"; do
    if (( skip )); then skip=0; continue; fi
    case "$token" in initcwnd|initrwnd) skip=1 ;; expires) return 1 ;; *) clean+=("$token") ;; esac
  done
  (( cw == 0 )) || clean+=(initcwnd "$cw")
  (( rw == 0 )) || clean+=(initrwnd "$rw")
  ip -4 route change "${clean[@]}"
}
restore_route_windows() {
  local iface cw rw value route
  [[ -f $ROUTE_STATE ]] || return 0
  IFS=$'\t' read -r iface cw rw value <"$ROUTE_STATE"
  is_safe_iface "$iface" || return 1
  route=$(ip -4 route show default dev "$iface") || return 1
  [[ -n $route ]] || { warn '原网卡暂时没有默认路由；初始窗口快照保留，稍后重试回滚。'; return 1; }
  route_with_windows "$route" "$cw" "$rw" || return 1
  rm -f "$ROUTE_STATE"
}
apply_route_windows() {
  local route iface cw rw temporary_file
  (( INITCWND > 0 )) || return 0
  [[ ! -e $ROUTE_STATE ]] || return 0
  route=$(ip -4 route show default) || return 1
  iface=$(route_field dev "$route")
  if [[ -z $route || $route == *$'\n'* || $route == *'nexthop '* ]] || ! is_safe_iface "$iface"; then
    warn '默认路由为多出口、IPv6-only 或特殊拓扑，已跳过初始窗口；基础 TCP 调优已保留。'; return 0
  fi
  cw=$(route_field initcwnd "$route"); rw=$(route_field initrwnd "$route")
  temporary_file=$(mktemp "$STATE_DIR/route-window.XXXXXX") || return 1
  printf '%s\t%s\t%s\t%s\n' "$iface" "${cw:-0}" "${rw:-0}" "$INITCWND" >"$temporary_file"
  mv -f "$temporary_file" "$ROUTE_STATE" || return 1
  if ! route_with_windows "$route" "$INITCWND" "$INITCWND"; then
    rm -f "$ROUTE_STATE"
    warn '当前路由不支持初始窗口设置；基础 TCP 调优已保留。'; return 0
  fi
  ok "已应用 initcwnd/initrwnd=$INITCWND，并保存原窗口；不写回旧网关。"
}
recover_runtime() {
  local iface kind spec cw rw value route
  if [[ -f $QDISC_TUNE_STATE && ! -f $SHAPE_STATE ]]; then
    IFS=$'\t' read -r iface kind spec <"$QDISC_TUNE_STATE"
    is_safe_iface "$iface" || return 1
    if ip link show dev "$iface" >/dev/null 2>&1 && ! active_qdisc_is_fq "$iface"; then
      kind=$(active_root_qdisc "$iface")
      # 不覆盖用户新加的 HTB、CAKE 等策略。
      case "$kind" in fq_codel|pfifo_fast|pfifo|bfifo|mq)
        if [[ $kind == mq ]]; then
          local temporary_file
          temporary_file=$(mktemp)
          qdisc_snapshot "$iface" "$temporary_file" >/dev/null || { rm -f "$temporary_file"; return 1; }
          apply_fq_candidate "$iface" mq "$temporary_file" || { rm -f "$temporary_file"; return 1; }
          rm -f "$temporary_file"
        else tc qdisc replace dev "$iface" root fq || return 1; fi ;;
      esac
    fi
  fi
  if [[ -f $ROUTE_STATE ]]; then
    IFS=$'\t' read -r iface cw rw value <"$ROUTE_STATE"
    is_safe_iface "$iface" && is_positive_integer "$value" && (( value <= 64 )) || return 1
    route=$(ip -4 route show default dev "$iface") || return 1
    if [[ -n $route ]] && { [[ $(route_field initcwnd "$route") != "$value" ]] || [[ $(route_field initrwnd "$route") != "$value" ]]; }; then
      route_with_windows "$route" "$value" "$value" || return 1
    fi
  fi
}
write_runtime_service() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] || {
    warn '系统未运行 systemd；当前调优有效，但活动 FQ/初始窗口无法自动在重启后恢复。'; return 0;
  }
  local path temporary_file
  for path in "$RUNTIME_SCRIPT" "$RUNTIME_UNIT" "$RUNTIME_TIMER"; do managed_file_or_absent "$path" "$RUNTIME_MARKER"; done
  temporary_file=$(mktemp "${RUNTIME_SCRIPT}.XXXXXX") || return 1
  {
    printf '#!/usr/bin/env bash\n%s\nset -Eeuo pipefail\n' "$RUNTIME_MARKER"
    printf 'readonly QDISC_TUNE_STATE=%q SHAPE_STATE=%q ROUTE_STATE=%q LOCK_FILE=%q\n' "$QDISC_TUNE_STATE" "$SHAPE_STATE" "$ROUTE_STATE" "$LOCK_FILE"
    declare -f is_safe_iface is_positive_integer route_field route_with_windows recover_runtime active_root_qdisc active_qdisc_is_fq qdisc_leaf_is_restorable qdisc_snapshot qdisc_snapshot_mq apply_fq_candidate
    printf 'exec 9>"$LOCK_FILE"\nflock -n 9 || exit 0\nrecover_runtime\n'
  } >"$temporary_file"
  chmod 700 "$temporary_file" && mv -f "$temporary_file" "$RUNTIME_SCRIPT" || return 1
  temporary_file=$(mktemp "${RUNTIME_UNIT}.XXXXXX") || return 1
  printf '%s\n[Unit]\nDescription=Restore managed TCP windows and FQ after network changes\nAfter=network-online.target\n[Service]\nType=oneshot\nExecStart=%s\nNoNewPrivileges=yes\nProtectSystem=strict\nReadWritePaths=/run/lock\nProtectHome=yes\nPrivateTmp=yes\nCapabilityBoundingSet=CAP_NET_ADMIN\n' "$RUNTIME_MARKER" "$RUNTIME_SCRIPT" >"$temporary_file"
  chmod 644 "$temporary_file" && mv -f "$temporary_file" "$RUNTIME_UNIT" || return 1
  temporary_file=$(mktemp "${RUNTIME_TIMER}.XXXXXX") || return 1
  printf '%s\n[Unit]\nDescription=Recheck managed TCP windows and FQ\n[Timer]\nOnBootSec=30s\nOnUnitInactiveSec=30s\nUnit=vps-tcp-safe-tuner-runtime.service\n[Install]\nWantedBy=timers.target\n' "$RUNTIME_MARKER" >"$temporary_file"
  chmod 644 "$temporary_file" && mv -f "$temporary_file" "$RUNTIME_TIMER" || return 1
  systemctl daemon-reload && systemctl enable --now vps-tcp-safe-tuner-runtime.timer
}
remove_runtime_service() {
  local path
  for path in "$RUNTIME_SCRIPT" "$RUNTIME_UNIT" "$RUNTIME_TIMER"; do managed_file_or_absent "$path" "$RUNTIME_MARKER"; done
  if [[ -e $RUNTIME_TIMER ]]; then systemctl disable --now vps-tcp-safe-tuner-runtime.timer || return 1; fi
  for path in "$RUNTIME_SCRIPT" "$RUNTIME_UNIT" "$RUNTIME_TIMER"; do remove_managed_file "$path" "$RUNTIME_MARKER"; done
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then systemctl daemon-reload; fi
}
wizard() {
  local saved_yes=$ASSUME_YES estimated_tests skip_heavy_tests=0
  require_root; require_linux; validate_common; ensure_iperf3
  [[ -n $PEER ]] || auto_pick_peer
  validate_peer
  if [[ -z $BANDWIDTH_MBIT ]]; then
    say '带宽留空：先用所选对端进行双向多轮容量探测，再按较大方向推导基础配置。'
    if ! measure; then fail '带宽探测没有取得可靠样本，未修改系统。请换一个可信对端后重试。'; fi
    BANDWIDTH_MBIT=$MEASURE_RATE
    if (( BIDIRECTIONAL )) && [[ -n ${MEASURE_REVERSE_RATE:-} ]] && (( MEASURE_REVERSE_RATE > BANDWIDTH_MBIT )); then BANDWIDTH_MBIT=$MEASURE_REVERSE_RATE; fi
    BUFFER_BANDWIDTH_MBIT=$(estimate_buffer_bandwidth "$BANDWIDTH_MBIT")
    say "实测容量约 ${BANDWIDTH_MBIT}Mbit/s；TCP 窗口按 ${BUFFER_BANDWIDTH_MBIT}Mbit/s 常见端口档位推导。"
  fi
  [[ -n $RTT_MS ]] || RTT_MS=$AUTO_TARGET_RTT_MS
  estimated_tests=$(( ROUNDS * 4 + POLICER_ROUNDS * 2 + 15 ))
  if ! guard_test_traffic '五阶段一键调优（最坏情况）' "$BANDWIDTH_MBIT" "$estimated_tests"; then
    if [[ -t 0 || $MENU_MODE == 1 ]] && confirm_high_traffic "预计流量超过默认 ${MAX_TEST_GIB}GiB 护栏；继续完整扫描吗？选择 N 仍会完成基础调优。"; then
      ALLOW_HIGH_TRAFFIC=1
    elif [[ -t 0 || $MENU_MODE == 1 ]]; then
      skip_heavy_tests=1
      warn '已选择 N：不会退出调优；将完成基础 TCP 调优，但跳过路径检测、拐点扫描和满速复测。'
    else
      fail '未获得高流量授权，未修改系统。可改用菜单2快速基础调优。'
    fi
  fi
  line
  say '五阶段流程：1 基础调优 → 2 40%路径质量 → 3 policer拐点扫描 → 4 候选整形 → 5 同对端复测。'
  say "带宽=${BANDWIDTH_MBIT}Mbit/s；目标RTT=${RTT_MS}ms；对端=$PEER:$PEER_PORT；用途=$ROLE。"
  confirm_default_yes '开始调优吗？选择过高流量 N 时将自动降级为基础调优。' || { say '已取消，未修改系统。'; return 0; }
  ASSUME_YES=1; WIZARD_MODE=1; ENABLE_SHAPING=0
  say '[1/5] 基础调优：快照、BBR、活动FQ、自适应缓冲区、丢包恢复与initcwnd。'
  tune
  (( TUNING_APPLIED )) || { ASSUME_YES=$saved_yes; WIZARD_MODE=0; return 0; }
  if (( skip_heavy_tests )); then
    say '[2/5–5/5] 已按你的 N 选择跳过高流量检测、扫描与复测；基础调优已经生效。'
    ASSUME_YES=$saved_yes; WIZARD_MODE=0
    line; ok '基础调优完成；未因拒绝高流量扫描而退出或撤销。'; line
    return 0
  fi
  say '[2/5] 路径质量检测：以40%套餐速率区分线路底噪与出口限速器丢包。'
  path_quality_check || true
  ENABLE_SHAPING=1
  tune_shaper
  ASSUME_YES=$saved_yes; WIZARD_MODE=0
  line; ok '五阶段一键调优完成；只有通过同对端复测的整形候选才会持久化。'; line
}
tune() {
  [[ -n $BANDWIDTH_MBIT ]] || fail 'tune 需要 --bandwidth（VPS 套餐或端口带宽，Mbit/s）。'
  if [[ -z $RTT_MS ]]; then
    RTT_MS=$AUTO_TARGET_RTT_MS
    say "未指定 --rtt，按跨境代理常用目标 ${RTT_MS}ms 推导缓冲区。"
  fi
  say '快速基础调优不依赖 iperf3 稳定性；将直接按套餐带宽、目标 RTT 和内存应用 BBR + FQ + 自适应缓冲区。'
  apply_tuning
  (( DRY_RUN == 0 && TUNING_APPLIED )) || return 0
  apply_route_windows || warn '初始窗口设置未完成；基础 TCP 配置已保留。'
  write_runtime_service || warn '网络恢复服务安装失败；当前配置已生效，重启恢复尚未完成。'
  if (( ENABLE_SHAPING )); then
    tune_shaper
  fi
}
deep() {
  BUFFER_SEARCH=1; QDISC_EXPERIMENT=1
  warn '深度模式会额外测试 1×/2×/3× BDP 与活动 FQ 候选，流量和耗时明显高于标准模式。'
  auto
}

audit() {
  require_linux; require_command sysctl; require_command ip; show_environment
  if kernel_supports_bbr; then say 'BBR 可用：是'; else say 'BBR 可用：否'; fi
  say "sysctl 配置目录：$([[ -d /etc/sysctl.d ]] && echo 可用 || echo 缺失)"; say "iperf3：$(command -v iperf3 >/dev/null 2>&1 && echo 已安装 || echo 未安装)"; say "systemd：$(command -v systemctl >/dev/null 2>&1 && echo 可用 || echo 不可用)"
  if report_sysctl_conflicts "${MANAGED_SYSCTL_KEYS[@]}"; then
    if (( SYSCTL_CONFLICT_COUNT )); then say "持久化 sysctl 重复项：${SYSCTL_CONFLICT_COUNT} 项，均早于本工具加载；无阻断项。"; else say '持久化 sysctl 冲突：未发现'; fi
  else
    warn "持久化 sysctl 阻断项：${SYSCTL_BLOCKING_CONFLICT_COUNT} 项；调优前必须处理或显式放行。"
  fi
  say '提示：选菜单 1、2 或 3 调优时，脚本会自动尝试加载内核已有的 tcp_bbr；OpenVZ/LXC 可能拒绝部分 sysctl 或 qdisc。'
}
status() {
  require_linux; require_command sysctl; show_environment
  [[ -f $CONFIG_FILE ]] && { say "持久化配置：$CONFIG_FILE"; yellow "$(sed -n '1,30p' "$CONFIG_FILE")"; printf '\n'; } || warn '未检测到本工具 sysctl 配置。'
  if [[ -f $CONFIG_FILE ]]; then
    if verify_managed_config_live; then ok '持久化配置与当前内核运行值逐项一致。'; else warn '持久化配置与运行值存在漂移；请不要假定调优仍然生效。'; fi
  fi
  [[ -f $FACTS_FILE ]] && { say '上次调优事实：'; yellow "$(cat "$FACTS_FILE")"; printf '\n'; }
  [[ -f $SNAPSHOT_FILE ]] && say "可回滚快照：$SNAPSHOT_FILE" || say '没有 sysctl 快照。'; [[ -f $SHAPE_STATE ]] && say "已存在本工具整形：$(tr '\t' ' ' <"$SHAPE_STATE")" || say '没有本工具整形。'
  [[ -f $QDISC_TUNE_STATE ]] && say "本工具已管理活动 FQ；原活动队列快照：$(tr '\t' ' ' <"$QDISC_TUNE_STATE")" || say '没有本工具管理的活动 qdisc。'
  if [[ -f $TRANSACTION_FILE ]]; then warn '检测到未完成的调优事务；请重新运行调优或执行回滚后再继续。'; fi
}
rollback() {
  require_root; require_linux; require_command sysctl; lock; [[ -f $SNAPSHOT_FILE ]] || fail '未找到首次快照；拒绝猜测系统原始值。'
  (( DRY_RUN )) && { say '将恢复 sysctl 与活动 qdisc 快照，并移除本工具配置和整形。'; return 0; }; confirm '恢复首次 sysctl/活动 qdisc 快照并移除本工具的持久化配置和整形吗？' || { say '已取消。'; return 0; }
  remove_runtime_service || fail '无法停止网络恢复服务；已保留状态，避免回滚后被重新应用。'
  restore_route_windows || fail '初始窗口恢复失败；路由快照保留，请恢复网卡连接后重试。'
  [[ -f $SHAPE_STATE ]] && { ASSUME_YES=1; unshape; }
  restore_snapshot_values || fail "部分 sysctl 恢复失败；配置和快照均已保留，请检查后重试：$SNAPSHOT_FILE"
  restore_managed_qdisc_tune || fail "sysctl 已恢复，但活动 qdisc 恢复失败；队列状态仍保留：$QDISC_TUNE_STATE"
  remove_bbr_module_config; rm -f "$CONFIG_FILE" "$SNAPSHOT_FILE" "$FACTS_FILE" "$TRANSACTION_FILE"; rmdir "$STATE_DIR" 2>/dev/null || true; ok '已恢复 sysctl 与活动 qdisc 快照，并清理本工具创建的持久化文件。'
}
menu() {
  require_linux; line; say "VPS TCP 自适应调优器 v$VERSION"; line
  yellow "$(cat <<'EOF'
1) 五阶段一键调优（推荐；测速、拐点扫描、自动整形、复测）
2) 快速基础调优（无测速；直接按套餐带宽应用）
3) 深度自适应实验（缓冲区 + FQ 双向 A/B，流量较大）
4) 按已知带宽/RTT 调优
5) 仅检测
6) 查看状态
7) 回滚
0) 退出
EOF
)"
  printf '\n'
  local choice; yellow '请选择：'; read -r choice
  case "$choice" in
    1)
      MENU_MODE=1
      yellow '[套餐带宽 Mbit/s（推荐填数字；回车则先自动测速）] '; read -r BANDWIDTH_MBIT
      yellow '[测速对端域名或 IPv4（回车自动选择公共节点）] '; read -r PEER
      yellow '[用途 general=通用 / proxy=代理加速 / server=建站服务，默认 proxy] '; read -r ROLE; ROLE=${ROLE:-proxy}
      wizard
      ;;
    2) yellow '[套餐带宽 Mbit/s] '; read -r BANDWIDTH_MBIT; yellow '[用途 general=通用 / proxy=代理加速 / server=建站服务，默认 proxy] '; read -r ROLE; ROLE=${ROLE:-proxy}; tune ;;
    3) yellow '[对端域名或 IPv4，回车自动选择公共节点] '; read -r PEER; yellow '[用途 general=通用 / proxy=代理加速 / server=建站服务，默认 general] '; read -r ROLE; ROLE=${ROLE:-general}; deep ;;
    4) yellow '[带宽 Mbit] '; read -r BANDWIDTH_MBIT; yellow '[典型 RTT ms] '; read -r RTT_MS; yellow '[用途 general=通用 / proxy=代理加速 / server=建站服务，默认 general] '; read -r ROLE; ROLE=${ROLE:-general}; apply_tuning ;;
    5) audit ;; 6) status ;; 7) rollback ;; 0) say '已退出。' ;; *) fail '无效选择。' ;;
  esac
}
parse_options() {
  while (($#)); do case "$1" in
    --peer) PEER=${2:-}; shift 2 ;; --port) PEER_PORT=${2:-}; shift 2 ;; --role) ROLE=${2:-}; shift 2 ;; --bandwidth) BANDWIDTH_MBIT=${2:-}; shift 2 ;; --rtt) RTT_MS=${2:-}; shift 2 ;; --duration) DURATION=${2:-}; shift 2 ;; --workers) WORKERS=${2:-}; shift 2 ;; --rounds) ROUNDS=${2:-}; shift 2 ;; --policer-rounds) POLICER_ROUNDS=${2:-}; shift 2 ;; --peer-max-rtt) PEER_MAX_RTT=${2:-}; shift 2 ;; --max-test-gib) MAX_TEST_GIB=${2:-}; shift 2 ;; --max-rate-spread) MAX_RATE_SPREAD_PERCENT=${2:-}; shift 2 ;; --shape-rate) SHAPE_RATE=${2:-}; shift 2 ;;
    --initcwnd) INITCWND=${2:-}; shift 2 ;;
    --enable-shaping) ENABLE_SHAPING=1; shift ;; --search-buffers) BUFFER_SEARCH=1; shift ;; --experiment-qdisc) QDISC_EXPERIMENT=1; shift ;; --allow-public-peers) ALLOW_PUBLIC_PEERS=1; shift ;; --allow-high-traffic) ALLOW_HIGH_TRAFFIC=1; shift ;; --allow-sysctl-conflicts) ALLOW_SYSCTL_CONFLICTS=1; shift ;; --forward-only) BIDIRECTIONAL=0; shift ;; --dry-run) DRY_RUN=1; shift ;; --yes) ASSUME_YES=1; shift ;; --no-install) NO_INSTALL=1; shift ;; --keep-on-regression) KEEP_ON_REGRESSION=1; shift ;; -h|--help) usage; exit 0 ;; *) fail "未知选项：$1" ;;
  esac; done
}
main() {
  COMMAND=${1:-menu}; shift || true; parse_options "$@"
  case "$COMMAND" in menu) menu ;; audit) audit ;; measure|verify) measure ;; wizard) wizard ;; tune) tune ;; auto) auto ;; deep) deep ;; apply) apply_tuning ;; shape) shape ;; unshape) unshape ;; status) status ;; rollback) rollback ;; help|-h|--help) usage ;; *) fail "未知命令：$COMMAND" ;; esac
}
if [[ ${VPS_TCP_TUNE_LIBRARY:-0} != 1 ]]; then
  main "$@"
fi
