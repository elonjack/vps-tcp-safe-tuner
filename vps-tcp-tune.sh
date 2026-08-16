#!/usr/bin/env bash
# vps-tcp-safe-tuner: 自适应、可测量、可回滚的 Linux VPS TCP 调优工具。
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly VERSION='3.6.1'
readonly STATE_DIR='/var/lib/vps-tcp-safe-tuner'
readonly SNAPSHOT_FILE="$STATE_DIR/baseline.tsv"
readonly FACTS_FILE="$STATE_DIR/facts.tsv"
readonly CONFIG_FILE='/etc/sysctl.d/99-vps-tcp-safe-tuner.conf'
readonly LOCK_FILE='/run/lock/vps-tcp-safe-tuner.lock'
readonly SHAPE_SCRIPT='/usr/local/sbin/vps-tcp-safe-tuner-qdisc'
readonly SHAPE_UNIT='/etc/systemd/system/vps-tcp-safe-tuner-qdisc.service'
readonly SHAPE_STATE="$STATE_DIR/qdisc.tsv"
readonly BBR_MODULE_FILE='/etc/modules-load.d/vps-tcp-safe-tuner-bbr.conf'
readonly REPORT_DIR='/var/log/vps-tcp-safe-tuner'
readonly MARKER='# Managed by vps-tcp-safe-tuner. Remove only with vps-tcp-tune rollback.'
readonly BBR_MODULE_MARKER='# Managed by vps-tcp-safe-tuner: load BBR at boot.'
readonly AUTO_TARGET_RTT_MS='150'

COMMAND='menu'; ROLE='general'; PEER=''; PEER_PORT='5201'; BANDWIDTH_MBIT=''; RTT_MS=''
DURATION='12'; WORKERS='4'; ROUNDS='3'; POLICER_ROUNDS='3'; PEER_MAX_RTT='120'; BUFFER_MULTIPLIER_OVERRIDE=''; SHAPE_RATE=''; ENABLE_SHAPING=0; BUFFER_SEARCH=0; DRY_RUN=0; ASSUME_YES=0; NO_INSTALL=0; KEEP_ON_REGRESSION=0
TUNING_APPLIED=0

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
  auto --peer 主机             实测后自动推导 BDP 并应用调优
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
  --enable-shaping     auto 成功后，允许进入限速器扫描和整形候选流程
  --search-buffers     对 1×、2×、3× BDP 缓冲区进行 A/B 测试并自动保留最佳候选
  --shape-rate MBIT    shape 使用的目标速率
  --no-install         不允许脚本安装 iperf3
  --keep-on-regression 即使复测明显退化，也不自动回滚（默认会回滚）
  --dry-run            仅显示动作，不写入系统
  --yes                非交互确认（整形仍要求 --enable-shaping）

示例：
  sudo bash vps-tcp-tune.sh audit
  sudo bash vps-tcp-tune.sh auto --peer 203.0.113.10 --role proxy
  sudo bash vps-tcp-tune.sh auto --rounds 3 --role proxy
  sudo bash vps-tcp-tune.sh auto --rtt 180 --role proxy
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

confirm() {
  local message=$1 answer
  (( ASSUME_YES )) && { say "$message（已由 --yes 确认）"; return 0; }
  [[ -t 0 ]] || fail '非交互运行需要 --yes；整形还需要 --enable-shaping。'
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
    ok 'BBR 已启用；本工具会在重启后自动加载 tcp_bbr。'
  else
    warn 'BBR 已在本次启动中启用；因同名模块配置不归本工具管理，未改动其重启加载行为。'
  fi
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
  [[ -z $BANDWIDTH_MBIT ]] || { is_positive_integer "$BANDWIDTH_MBIT" && (( BANDWIDTH_MBIT <= 100000 )) || fail '--bandwidth 必须是 1 到 100000 的整数。'; }
  [[ -z $RTT_MS ]] || { is_positive_integer "$RTT_MS" && (( RTT_MS <= 3000 )) || fail '--rtt 必须是 1 到 3000 的整数。'; }
}
validate_peer() { [[ -n $PEER ]] || fail '未取得可用 iperf3 对端。'; [[ $PEER =~ ^[A-Za-z0-9._-]+$ ]] || fail '--peer 仅允许域名或 IPv4 地址；IPv6 请用 DNS 名称。'; }

auto_pick_peer() {
  local candidate location provider rtt ranked host port probe
  local -a ports=(5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200)
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
    for port in "${ports[@]}"; do
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
MEASURE_RATE=''; MEASURE_RETRANS=''; MEASURE_RTT=''; MEASURE_OUTPUT=''

measure_rtt() {
  MEASURE_RTT=''; command -v ping >/dev/null 2>&1 || return 0
  local summary
  summary=$(ping -n -c 4 -W 2 "$PEER" 2>/dev/null | awk -F' = ' '/min\/avg\/max/ {print $2}' | tail -n 1 || true)
  [[ -n $summary ]] && MEASURE_RTT=$(awk -F/ '{printf "%.0f",$2}' <<<"$summary")
}
parse_iperf_result() {
  local output=$1 raw raw_rate raw_unit
  raw=$(awk '$NF == "receiver" {for(i=1;i<=NF;i++)if($i~/^[KMGTP]?bits\/sec$/){rate=$(i-1);unit=$i}} END{if(rate!="")print rate,unit}' <<<"$output")
  [[ -n $raw ]] || return 1
  raw_rate=${raw%% *}; raw_unit=${raw##* }; MEASURE_RATE=$(rate_to_mbit "$raw_rate" "$raw_unit")
  MEASURE_RETRANS=$(awk '$NF == "sender" {value=$(NF-1)} END{if(value!="")print value;else print 0}' <<<"$output")
}
measure() {
  require_linux; require_command timeout; validate_common; ensure_iperf3
  [[ -n $PEER ]] || auto_pick_peer
  validate_peer
  local temporary_file round valid required rate retrans median_position estimated_mb
  temporary_file=$(mktemp)
  chmod 600 "$temporary_file"
  valid=0
  required=$(( (ROUNDS + 1) / 2 ))
  say "开始 ${ROUNDS} 轮测试：对端=$PEER:$PEER_PORT，并发=$WORKERS，单轮=${DURATION}s。"
  say '测试会产生实际流量；为降低偶发波动影响，最终使用有效轮次的中位吞吐。'
  for ((round = 1; round <= ROUNDS; round += 1)); do
    MEASURE_OUTPUT=$(timeout "$(( DURATION + 15 ))" iperf3 -c "$PEER" -p "$PEER_PORT" -P "$WORKERS" -t "$DURATION" --omit 2 2>&1) || {
      warn "第 $round 轮测试失败，已跳过。"
      continue
    }
    if ! parse_iperf_result "$MEASURE_OUTPUT"; then
      warn "第 $round 轮输出无法解析，已跳过。"
      continue
    fi
    rate=$MEASURE_RATE; retrans=$MEASURE_RETRANS
    printf '%s\t%s\n' "$rate" "$retrans" >>"$temporary_file"
    valid=$(( valid + 1 ))
    say "第 $round 轮：${rate} Mbit/s，重传 ${retrans}。"
  done
  if (( valid < required )); then
    rm -f "$temporary_file"
    fail "仅 $valid/$ROUNDS 轮测试有效，少于所需的 $required 轮；拒绝据此调优。"
  fi
  median_position=$(( (valid + 1) / 2 ))
  MEASURE_RATE=$(sort -n -k 1,1 "$temporary_file" | awk -v position="$median_position" 'NR == position {print $1}')
  MEASURE_RETRANS=$(awk -F'\t' '{total += $2} END {printf "%.0f", total}' "$temporary_file")
  estimated_mb=$(awk -v rate="$MEASURE_RATE" -v seconds="$DURATION" -v count="$valid" 'BEGIN {printf "%.0f", rate * seconds * count / 8}')
  rm -f "$temporary_file"
  measure_rtt
  line
  say "有效轮次：$valid/$ROUNDS；中位吞吐：${MEASURE_RATE} Mbit/s。"
  say "有效轮次累计发送端重传：${MEASURE_RETRANS}；估算测试流量约 ${estimated_mb} MB。"
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
calculate_buffer() {
  local bdp multiplier cap result memory
  memory=$(memory_mib); case "$ROLE" in proxy) multiplier=3 ;; *) multiplier=2 ;; esac
  [[ -z $BUFFER_MULTIPLIER_OVERRIDE ]] || multiplier=$BUFFER_MULTIPLIER_OVERRIDE
  # BDP（字节）= 带宽 Mbit/s × RTT ms × 125；不能遗漏 Mbit/ms 到字节的单位换算。
  bdp=$(( BANDWIDTH_MBIT * RTT_MS * 125 )); cap=$(( memory * 1024 * 1024 / 12 )); (( cap > 134217728 )) && cap=134217728
  result=$(( bdp * multiplier )); (( result < 4194304 )) && result=4194304; (( result > cap )) && result=$cap; (( result < 4194304 )) && result=4194304
  printf '%s' "$result"
}
calculate_initial_buffer() {
  local ceiling=$1 initial
  # 代理连接需更快完成请求/首包交换；上限仍由 BDP 和内存限制。
  case "$ROLE" in
    proxy) initial=1048576 ;;
    *) initial=524288 ;;
  esac
  (( initial > ceiling )) && initial=$ceiling
  printf '%s' "$initial"
}
calculate_backlog() { if (( BANDWIDTH_MBIT >= 5000 )); then printf 20000; elif (( BANDWIDTH_MBIT >= 1000 )); then printf 10000; elif (( BANDWIDTH_MBIT >= 200 )); then printf 5000; else printf 2500; fi; }

declare -a KEYS=() VALUES=()
add_setting() { sysctl_exists "$1" || { warn "内核不支持 $1，已跳过。"; return 0; }; KEYS+=("$1"); VALUES+=("$2"); }
build_settings() {
  local buffer initial_buffer backlog socket_queue syn_queue
  KEYS=(); VALUES=()
  buffer=$(calculate_buffer); initial_buffer=$(calculate_initial_buffer "$buffer"); backlog=$(calculate_backlog); case "$ROLE" in proxy|server) socket_queue=8192; syn_queue=8192 ;; *) socket_queue=4096; syn_queue=4096 ;; esac
  add_setting net.core.default_qdisc fq; add_setting net.ipv4.tcp_congestion_control bbr
  add_setting net.core.rmem_max "$buffer"; add_setting net.core.wmem_max "$buffer"
  add_setting net.ipv4.tcp_rmem "4096 $initial_buffer $buffer"; add_setting net.ipv4.tcp_wmem "4096 $initial_buffer $buffer"
  add_setting net.ipv4.tcp_mtu_probing 1; add_setting net.ipv4.tcp_slow_start_after_idle 0; add_setting net.ipv4.tcp_moderate_rcvbuf 1
  add_setting net.core.netdev_max_backlog "$backlog"; add_setting net.core.somaxconn "$socket_queue"; add_setting net.ipv4.tcp_max_syn_backlog "$syn_queue"
  [[ $ROLE != proxy ]] || add_setting net.ipv4.ip_local_port_range '10240 65535'
  ((${#KEYS[@]})) || fail '没有可写入的调优项。'
}

show_environment() {
  local iface
  iface=$(default_interface); line; say "版本：$VERSION；内核：$(uname -r)；虚拟化：$(virtualization)"
  say "内存：$(memory_mib) MiB；默认网卡：${iface:-未检测到}"; say "拥塞控制：$(sysctl_value net.ipv4.tcp_congestion_control)；默认 qdisc：$(sysctl_value net.core.default_qdisc)"
  [[ -z $iface ]] || say "活动根 qdisc：$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print $2}')"; line
}
show_plan() {
  local i buffer initial_buffer; buffer=$(calculate_buffer); initial_buffer=$(calculate_initial_buffer "$buffer"); show_environment
  say "用途=$ROLE；带宽=${BANDWIDTH_MBIT} Mbit/s；业务目标 RTT=${RTT_MS} ms；推导缓冲区上限=${buffer} 字节；初始收发缓冲区=${initial_buffer} 字节。"
  for i in "${!KEYS[@]}"; do say "${KEYS[$i]}：$(sysctl_value "${KEYS[$i]}") -> ${VALUES[$i]}"; done
  say '默认 qdisc 不会替换现有活动根队列；只有明确执行 shape 时才会改动它。'
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
write_facts() {
  install -d -m 700 "$STATE_DIR"
  { printf 'role\t%s\n' "$ROLE"; printf 'bandwidth_mbit\t%s\n' "$BANDWIDTH_MBIT"; printf 'target_rtt_ms\t%s\n' "$RTT_MS"; printf 'test_peer_rtt_ms\t%s\n' "${MEASURE_RTT:-}"; printf 'buffer_bdp_multiplier\t%s\n' "${BUFFER_MULTIPLIER_OVERRIDE:-default}"; printf 'peer\t%s\n' "$PEER"; printf 'measured_mbit\t%s\n' "${MEASURE_RATE:-}"; printf 'measured_retrans\t%s\n' "${MEASURE_RETRANS:-}"; } >"$FACTS_FILE"
  chmod 600 "$FACTS_FILE"
}
write_experiment_report() {
  local baseline_rate=$1 baseline_retrans=$2 after_rate=$3 after_retrans=$4 decision=$5 report_file
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
    printf 'buffer_bdp_multiplier\t%s\n' "${BUFFER_MULTIPLIER_OVERRIDE:-default}"
    printf 'baseline_mbit\t%s\n' "$baseline_rate"
    printf 'baseline_retrans\t%s\n' "$baseline_retrans"
    printf 'after_mbit\t%s\n' "$after_rate"
    printf 'after_retrans\t%s\n' "$after_retrans"
    awk -v before="$baseline_rate" -v after="$after_rate" 'BEGIN {if (before > 0) printf "gain_percent\t%.2f\n", (after-before)*100/before}'
  } >"$report_file"
  chmod 600 "$report_file"
  say "实验报告：$report_file"
}
is_material_regression() {
  local baseline_rate=$1 baseline_retrans=$2 after_rate=$3 after_retrans=$4
  (( after_rate * 100 < baseline_rate * 85 )) && return 0
  (( baseline_retrans == 0 && after_retrans > 10 )) && return 0
  return 1
}
revert_auto_experiment() {
  warn '复测显示明显退化，正在恢复本次 TCP 参数。'
  restore_snapshot_values
  remove_bbr_module_config; rm -f "$CONFIG_FILE" "$FACTS_FILE" "$SNAPSHOT_FILE"
  rmdir "$STATE_DIR" 2>/dev/null || true
  ok '已自动回滚本次实验参数；实验报告仍保留。'
}
write_config() {
  local tmp i; tmp=$(mktemp "${CONFIG_FILE}.XXXXXX"); chmod 644 "$tmp"
  { printf '%s\n' "$MARKER"; printf '# role=%s bandwidth=%sMbit rtt=%sms generated=%s\n' "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; for i in "${!KEYS[@]}"; do printf '%s = %s\n' "${KEYS[$i]}" "${VALUES[$i]}"; done; } >"$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}
restore_snapshot_values() {
  local key value; [[ -f $SNAPSHOT_FILE ]] || return 0
  while IFS=$'\t' read -r key value; do [[ -z $key ]] || { sysctl_exists "$key" && sysctl -q -w "$key=$value" || warn "恢复 $key 失败。"; }; done <"$SNAPSHOT_FILE"
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
  local index
  for index in "${!KEYS[@]}"; do
    sysctl -q -w "${KEYS[$index]}=${VALUES[$index]}" || return 1
  done
}
apply_tuning() {
  TUNING_APPLIED=0
  require_root; require_linux; require_command sysctl; require_command ip; require_command tc; lock; validate_common; derive_network_facts; build_settings; show_plan
  (( DRY_RUN )) && { ok '预览完成，未修改系统。'; return 0; }; confirm '将自动启用内核已有的 BBR（如尚未加载）、写入 sysctl、保存精确快照并立即应用自适应 TCP 参数。继续吗？' || { say '已取消。'; return 0; }
  ensure_bbr
  snapshot_if_needed
  if ! restore_legacy_core_defaults; then
    warn '旧版全局 socket 默认值恢复失败，正在恢复首次快照。'
    restore_snapshot_values; remove_bbr_module_config
    fail '调优失败，已执行回滚。'
  fi
  if ! apply_built_settings; then
    warn '候选 sysctl 应用失败，正在恢复首次快照。'
    restore_snapshot_values; remove_bbr_module_config
    fail '调优失败，已执行回滚。'
  fi
  write_config; write_facts; TUNING_APPLIED=1; ok "已应用 ${#KEYS[@]} 项自适应 TCP 设置。"
}
search_buffer_candidates() {
  local saved_override=$BUFFER_MULTIPLIER_OVERRIDE saved_rounds=$ROUNDS candidate candidate_rate candidate_retrans best_multiplier='' best_rate=0 best_retrans=0
  local -a candidates=(1 2 3)
  say '开始 BDP 缓冲区 A/B 搜索：分别测试 1×、2×、3× BDP 上限。'
  say '每个候选使用两轮测试；仅保留吞吐最高且重传不明显恶化的候选。'
  ROUNDS=2
  for candidate in "${candidates[@]}"; do
    BUFFER_MULTIPLIER_OVERRIDE=$candidate
    build_settings
    if ! apply_built_settings; then
      warn "${candidate}× BDP 参数无法应用，已跳过。"
      continue
    fi
    measure
    candidate_rate=$MEASURE_RATE; candidate_retrans=$MEASURE_RETRANS
    say "${candidate}× BDP：中位吞吐 ${candidate_rate}Mbit，累计重传 ${candidate_retrans}。"
    if (( candidate_retrans <= 10 && candidate_rate > best_rate )); then
      best_multiplier=$candidate; best_rate=$candidate_rate; best_retrans=$candidate_retrans
    fi
  done
  ROUNDS=$saved_rounds
  if [[ -z $best_multiplier ]]; then
    BUFFER_MULTIPLIER_OVERRIDE=$saved_override
    build_settings
    apply_built_settings || { restore_snapshot_values; fail '所有缓冲区候选均失败，已恢复快照。'; }
    warn '没有重传可接受的缓冲区候选，已恢复搜索前配置。'
    return 0
  fi
  BUFFER_MULTIPLIER_OVERRIDE=$best_multiplier
  build_settings
  apply_built_settings || { restore_snapshot_values; fail '最佳缓冲区候选应用失败，已恢复快照。'; }
  write_config
  say "已选择 ${best_multiplier}× BDP 缓冲区：${best_rate}Mbit，累计重传 ${best_retrans}。"
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
    local IFS=' '
    read -r -a arguments <<<"$spec"
  fi
  tc qdisc replace dev "$iface" root "$kind" "${arguments[@]}"
}
remove_qdisc_snapshot() {
  [[ ${1:-} == "$STATE_DIR"/qdisc-before-shape.* || ${1:-} == "$STATE_DIR"/qdisc-scan.* ]] && rm -f -- "$1"
}
write_shape_service() {
  local iface=$1 rate=$2 original=$3 original_spec=$4
  install -d -m 700 "$STATE_DIR"; printf '%s\t%s\t%s\t%s\n' "$iface" "$rate" "$original" "$original_spec" >"$SHAPE_STATE"; chmod 600 "$SHAPE_STATE"
  cat >"$SHAPE_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
tc qdisc replace dev '$iface' root handle 1: htb default 10
tc class replace dev '$iface' parent 1: classid 1:10 htb rate ${rate}mbit ceil ${rate}mbit
tc qdisc replace dev '$iface' parent 1:10 handle 10: fq
EOF
  chmod 700 "$SHAPE_SCRIPT"
  cat >"$SHAPE_UNIT" <<EOF
[Unit]
Description=VPS TCP Safe Tuner egress shaper
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$SHAPE_SCRIPT
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SHAPE_UNIT"; systemctl daemon-reload; systemctl enable vps-tcp-safe-tuner-qdisc.service >/dev/null
}
apply_shape() { tc qdisc replace dev "$1" root handle 1: htb default 10; tc class replace dev "$1" parent 1: classid 1:10 htb rate "${2}mbit" ceil "${2}mbit"; tc qdisc replace dev "$1" parent 1:10 handle 10: fq; }
shape() {
  require_root; require_linux; require_command tc; require_command systemctl; lock; validate_common; is_positive_integer "$SHAPE_RATE" || fail 'shape 需要 --shape-rate 正整数。'; (( SHAPE_RATE <= 100000 )) || fail '--shape-rate 不能超过 100000 Mbit/s。'
  local iface original original_spec snapshot qdisc_backup
  (( ENABLE_SHAPING )) || fail '整形必须显式加入 --enable-shaping。'
  iface=$(default_interface); [[ -n $iface ]] || fail '未检测到默认出口网卡。'
  install -d -m 700 "$STATE_DIR"; qdisc_backup=$(mktemp "$STATE_DIR/qdisc-before-shape.XXXXXX")
  snapshot=$(qdisc_snapshot "$iface" "$qdisc_backup") || { rm -f -- "$qdisc_backup"; fail '当前根 qdisc 无法精确重建；为避免破坏多队列或特殊配置，拒绝整形。'; }
  IFS=$'\t' read -r original original_spec <<<"$snapshot"
  [[ $original == mq ]] || rm -f -- "$qdisc_backup"
  line; warn "整形将暂时替换 $iface 的活动根 qdisc=$original，可能短暂影响连接。"; [[ $original == mq ]] && say '已保存 mq 的每个可恢复叶子 qdisc 参数。' || say "已保存根队列参数：${original_spec:-默认参数}"; say "目标速率：${SHAPE_RATE} Mbit/s；叶子队列：FQ；重启后由 systemd 恢复。"
  (( DRY_RUN )) && { remove_qdisc_snapshot "$qdisc_backup"; ok '整形预览完成，未修改系统。'; return 0; }; confirm '确认应用 HTB + FQ 出向整形吗？' || { remove_qdisc_snapshot "$qdisc_backup"; say '已取消。'; return 0; }; write_shape_service "$iface" "$SHAPE_RATE" "$original" "$original_spec"
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
  (( DRY_RUN )) && { say "将恢复 $iface 的根 qdisc 为 $original。"; return 0; }; confirm "移除 ${rate}Mbit 整形并恢复 $original 吗？" || { say '已取消。'; return 0; }
  systemctl disable --now vps-tcp-safe-tuner-qdisc.service >/dev/null 2>&1 || true; rm -f "$SHAPE_UNIT" "$SHAPE_SCRIPT"; systemctl daemon-reload
  restore_root_qdisc "$iface" "$original" "$original_spec" || fail '恢复根 qdisc 参数失败；整形状态文件已保留，可检查后重试。'
  remove_qdisc_snapshot "$original_spec"; rm -f "$SHAPE_STATE"; ok '已移除本工具整形并恢复根 qdisc 参数。'
}
policer_candidate_is_clean() {
  local rate=$1 retrans=$2 target_rate=$3 baseline_retrans=$4 allowed_retrans
  allowed_retrans=$(( baseline_retrans / 4 + 10 ))
  (( retrans <= allowed_retrans && rate * 100 >= target_rate * 90 ))
}
probe_shaper_candidate() {
  local iface=$1 original=$2 original_spec=$3 candidate_rate=$4 baseline_retrans=$5
  apply_shape "$iface" "$candidate_rate" || return 2
  if ! measure; then
    restore_root_qdisc "$iface" "$original" "$original_spec" || return 2
    return 2
  fi
  restore_root_qdisc "$iface" "$original" "$original_spec" || return 2
  say "扫描 ${candidate_rate}Mbit：中位吞吐 ${MEASURE_RATE}Mbit，累计重传 ${MEASURE_RETRANS}。"
  policer_candidate_is_clean "$MEASURE_RATE" "$MEASURE_RETRANS" "$candidate_rate" "$baseline_retrans"
}
scan_shaper_candidate() {
  validate_peer; ensure_iperf3; require_command tc
  local nominal candidate best='' last_clean='' broke_at='' iface original original_spec snapshot saved_rounds baseline_retrans qdisc_backup probe_status safe_rate
  local -a coarse=(85 92 99 106 114 123 133 145)
  iface=$(default_interface); [[ -n $iface ]] || fail '未检测到默认出口网卡。'
  install -d -m 700 "$STATE_DIR"; qdisc_backup=$(mktemp "$STATE_DIR/qdisc-scan.XXXXXX")
  snapshot=$(qdisc_snapshot "$iface" "$qdisc_backup") || { rm -f -- "$qdisc_backup"; fail '当前根 qdisc 无法精确重建，拒绝扫描整形。'; }
  IFS=$'\t' read -r original original_spec <<<"$snapshot"
  [[ $original == mq ]] || rm -f -- "$qdisc_backup"
  nominal=$BANDWIDTH_MBIT
  baseline_retrans=${MEASURE_RETRANS:-0}
  say "开始限速器拐点扫描：以 ${nominal}Mbit 基线从 85% 到 145% 自适应粗扫。"
  say "每个候选使用 ${POLICER_ROUNDS} 轮测试；判定会同时参考基线重传噪声和送达率。"
  say '发现拐点后使用二分法精扫；每轮临时 HTB+FQ 后都会恢复原 qdisc。'
  confirm "扫描会暂时替换 $iface 的根 qdisc，预计消耗较多流量。继续吗？" || { remove_qdisc_snapshot "$qdisc_backup"; say '已跳过扫描。'; return 0; }
  saved_rounds=$ROUNDS; ROUNDS=$POLICER_ROUNDS
  trap 'restore_root_qdisc "$iface" "$original" "$original_spec" >/dev/null 2>&1 || true; remove_qdisc_snapshot "$qdisc_backup"; ROUNDS=$saved_rounds' EXIT
  trap 'exit 130' INT TERM HUP
  for candidate in "${coarse[@]}"; do
    SHAPE_RATE=$(( nominal * candidate / 100 ))
    if probe_shaper_candidate "$iface" "$original" "$original_spec" "$SHAPE_RATE" "$baseline_retrans"; then
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
    while (( broke_at - last_clean > 1 )); do
      candidate=$(( (last_clean + broke_at) / 2 ))
      if probe_shaper_candidate "$iface" "$original" "$original_spec" "$candidate" "$baseline_retrans"; then
        last_clean=$candidate; best=$candidate
      else
        probe_status=$?
        (( probe_status == 1 )) || fail '二分精扫应用或恢复失败，已触发 qdisc 恢复保护。'
        broke_at=$candidate
      fi
    done
  fi
  ROUNDS=$saved_rounds
  restore_root_qdisc "$iface" "$original" "$original_spec" || fail '扫描结束时恢复根 qdisc 参数失败，请立即检查网络状态。'
  trap - EXIT INT TERM HUP
  remove_qdisc_snapshot "$qdisc_backup"
  if [[ -n $best && -n $broke_at ]]; then
    safe_rate=$(( best * 97 / 100 )); (( safe_rate < 1 )) && safe_rate=1
    say "建议整形速率：${safe_rate} Mbit/s（拐点前 ${best}Mbit 留出 3% 余量）。"
    say "请用 shape --shape-rate ${safe_rate} --enable-shaping 后再 verify。"
  else
    warn '扫描范围内没有确认的限速器拐点，不建议盲目整形。'
  fi
}
auto() {
  local baseline_rate baseline_retrans after_rate after_retrans decision
  require_root; require_linux; validate_common
  say '阶段 1/3：记录调优前基线。'
  measure
  baseline_rate=$MEASURE_RATE; baseline_retrans=$MEASURE_RETRANS
  BANDWIDTH_MBIT=$MEASURE_RATE
  if [[ -z $RTT_MS ]]; then
    RTT_MS=$AUTO_TARGET_RTT_MS
    say "测速对端 RTT 为 ${MEASURE_RTT:-未取得}ms，仅用于测量质量；BDP 按跨境业务默认目标 RTT ${RTT_MS}ms 推导。"
  else
    say "BDP 使用你指定的业务目标 RTT ${RTT_MS}ms；测速对端 RTT 为 ${MEASURE_RTT:-未取得}ms。"
  fi
  derive_network_facts
  say '阶段 2/3：应用按基线推导的候选配置。'
  apply_tuning
  (( TUNING_APPLIED )) || { say '候选配置未应用，已结束实验。'; return 0; }
  if (( BUFFER_SEARCH )); then
    say '附加阶段：搜索当前线路更合适的 BDP 缓冲区倍率。'
    search_buffer_candidates
  fi
  say '阶段 3/3：使用同一对端、同一轮次复测。'
  measure
  after_rate=$MEASURE_RATE; after_retrans=$MEASURE_RETRANS
  decision='retained'
  if is_material_regression "$baseline_rate" "$baseline_retrans" "$after_rate" "$after_retrans"; then
    if (( KEEP_ON_REGRESSION )); then
      decision='retained_by_override'
      warn '复测出现明显退化，但你指定了 --keep-on-regression，配置将保留。'
    else
      decision='rolled_back_regression'
    fi
  fi
  write_experiment_report "$baseline_rate" "$baseline_retrans" "$after_rate" "$after_retrans" "$decision"
  if [[ $decision == rolled_back_regression ]]; then
    revert_auto_experiment
    return 0
  fi
  write_facts
  ok '复测未出现明显退化，已保留候选 TCP 配置。'
  if (( ENABLE_SHAPING )); then
    if [[ $MEASURE_RETRANS == 0 ]]; then say '验证无重传，跳过限速器扫描。';
    else warn '已启用限速器候选扫描。扫描只给出建议，不会持久化整形。'; scan_shaper_candidate; fi
  fi
}

audit() {
  require_linux; require_command sysctl; require_command ip; show_environment
  if kernel_supports_bbr; then say 'BBR 可用：是'; else say 'BBR 可用：否'; fi
  say "sysctl 配置目录：$([[ -d /etc/sysctl.d ]] && echo 可用 || echo 缺失)"; say "iperf3：$(command -v iperf3 >/dev/null 2>&1 && echo 已安装 || echo 未安装)"; say "systemd：$(command -v systemctl >/dev/null 2>&1 && echo 可用 || echo 不可用)"
  say '提示：选菜单 1 或 2 调优时，脚本会自动尝试加载内核已有的 tcp_bbr；OpenVZ/LXC 可能拒绝部分 sysctl 或 qdisc。'
}
status() {
  require_linux; require_command sysctl; show_environment
  [[ -f $CONFIG_FILE ]] && { say "持久化配置：$CONFIG_FILE"; yellow "$(sed -n '1,30p' "$CONFIG_FILE")"; printf '\n'; } || warn '未检测到本工具 sysctl 配置。'
  [[ -f $FACTS_FILE ]] && { say '上次调优事实：'; yellow "$(cat "$FACTS_FILE")"; printf '\n'; }
  [[ -f $SNAPSHOT_FILE ]] && say "可回滚快照：$SNAPSHOT_FILE" || say '没有 sysctl 快照。'; [[ -f $SHAPE_STATE ]] && say "已存在本工具整形：$(tr '\t' ' ' <"$SHAPE_STATE")" || say '没有本工具整形。'
}
rollback() {
  require_root; require_linux; require_command sysctl; lock; [[ -f $SNAPSHOT_FILE ]] || fail '未找到首次快照；拒绝猜测系统原始值。'
  (( DRY_RUN )) && { say '将恢复 sysctl 快照并移除本工具配置和整形。'; return 0; }; confirm '恢复首次 sysctl 快照并移除本工具的持久化配置/整形吗？' || { say '已取消。'; return 0; }
  [[ -f $SHAPE_STATE ]] && { ASSUME_YES=1; unshape; }; restore_snapshot_values; remove_bbr_module_config; rm -f "$CONFIG_FILE" "$SNAPSHOT_FILE" "$FACTS_FILE"; rmdir "$STATE_DIR" 2>/dev/null || true; ok '已恢复快照并清理本工具创建的持久化文件。'
}
menu() {
  require_linux; line; say "VPS TCP 自适应调优器 v$VERSION"; line
  yellow "$(cat <<'EOF'
1) 自适应测试并调优（需要可信 iperf3 对端）
2) 按已知带宽/RTT 调优
3) 仅检测
4) 查看状态
5) 回滚
0) 退出
EOF
)"
  printf '\n'
  local choice; yellow '请选择：'; read -r choice
  case "$choice" in
    1) yellow '[对端域名或 IPv4，回车自动选择公共节点] '; read -r PEER; yellow '[用途 general=通用 / proxy=代理加速 / server=建站服务，默认 general] '; read -r ROLE; ROLE=${ROLE:-general}; auto ;;
    2) yellow '[带宽 Mbit] '; read -r BANDWIDTH_MBIT; yellow '[典型 RTT ms] '; read -r RTT_MS; yellow '[用途 general=通用 / proxy=代理加速 / server=建站服务，默认 general] '; read -r ROLE; ROLE=${ROLE:-general}; apply_tuning ;;
    3) audit ;; 4) status ;; 5) rollback ;; 0) say '已退出。' ;; *) fail '无效选择。' ;;
  esac
}
parse_options() {
  while (($#)); do case "$1" in
    --peer) PEER=${2:-}; shift 2 ;; --port) PEER_PORT=${2:-}; shift 2 ;; --role) ROLE=${2:-}; shift 2 ;; --bandwidth) BANDWIDTH_MBIT=${2:-}; shift 2 ;; --rtt) RTT_MS=${2:-}; shift 2 ;; --duration) DURATION=${2:-}; shift 2 ;; --workers) WORKERS=${2:-}; shift 2 ;; --rounds) ROUNDS=${2:-}; shift 2 ;; --policer-rounds) POLICER_ROUNDS=${2:-}; shift 2 ;; --shape-rate) SHAPE_RATE=${2:-}; shift 2 ;;
    --enable-shaping) ENABLE_SHAPING=1; shift ;; --search-buffers) BUFFER_SEARCH=1; shift ;; --dry-run) DRY_RUN=1; shift ;; --yes) ASSUME_YES=1; shift ;; --no-install) NO_INSTALL=1; shift ;; --keep-on-regression) KEEP_ON_REGRESSION=1; shift ;; -h|--help) usage; exit 0 ;; *) fail "未知选项：$1" ;;
  esac; done
}
main() {
  COMMAND=${1:-menu}; shift || true; parse_options "$@"
  case "$COMMAND" in menu) menu ;; audit) audit ;; measure|verify) measure ;; auto) auto ;; apply) apply_tuning ;; shape) shape ;; unshape) unshape ;; status) status ;; rollback) rollback ;; help|-h|--help) usage ;; *) fail "未知命令：$COMMAND" ;; esac
}
if [[ ${VPS_TCP_TUNE_LIBRARY:-0} != 1 ]]; then
  main "$@"
fi
