#!/usr/bin/env bash
# vps-tcp-safe-tuner: 自适应、可测量、可回滚的 Linux VPS TCP 调优工具。
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly VERSION='2.0.0'
readonly STATE_DIR='/var/lib/vps-tcp-safe-tuner'
readonly SNAPSHOT_FILE="$STATE_DIR/baseline.tsv"
readonly FACTS_FILE="$STATE_DIR/facts.tsv"
readonly CONFIG_FILE='/etc/sysctl.d/99-vps-tcp-safe-tuner.conf'
readonly LOCK_FILE='/run/lock/vps-tcp-safe-tuner.lock'
readonly SHAPE_SCRIPT='/usr/local/sbin/vps-tcp-safe-tuner-qdisc'
readonly SHAPE_UNIT='/etc/systemd/system/vps-tcp-safe-tuner-qdisc.service'
readonly SHAPE_STATE="$STATE_DIR/qdisc.tsv"
readonly MARKER='# Managed by vps-tcp-safe-tuner. Remove only with vps-tcp-tune rollback.'

COMMAND='menu'; ROLE='general'; PEER=''; PEER_PORT='5201'; BANDWIDTH_MBIT=''; RTT_MS=''
DURATION='12'; WORKERS='4'; SHAPE_RATE=''; ENABLE_SHAPING=0; DRY_RUN=0; ASSUME_YES=0; NO_INSTALL=0

# 第三方公开 iperf3 节点。自动模式会按 RTT 排序、依次做短测试；用户也可用 --peer 覆盖。
# 节点可用性会变化，因此自动选择失败时会给出明确提示，不会伪造测量结果。
readonly PUBLIC_PEERS='
speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb
speedtest.sin1.sg.leaseweb.net|新加坡|Leaseweb
sgp.proof.ovh.net|新加坡|OVH
speedtest.tyo11.jp.leaseweb.net|东京|Leaseweb
speedtest.fra1.de.leaseweb.net|法兰克福|Leaseweb
speedtest.ams2.nl.leaseweb.net|阿姆斯特丹|Leaseweb
speedtest.lon12.uk.leaseweb.net|伦敦|Leaseweb
speedtest.lax12.us.leaseweb.net|洛杉矶|Leaseweb
speedtest.sfo12.us.leaseweb.net|旧金山|Leaseweb
speedtest.sea11.us.leaseweb.net|西雅图|Leaseweb
speedtest.dal13.us.leaseweb.net|达拉斯|Leaseweb
speedtest.chi11.us.leaseweb.net|芝加哥|Leaseweb
speedtest.nyc1.us.leaseweb.net|纽约|Leaseweb
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
  measure --peer 主机          以指定 iperf3 服务端做吞吐、重传、RTT 基线测试
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
  --rtt MS             典型 RTT（毫秒）
  --duration SEC       单次 iperf3 测试时长，默认 12 秒
  --workers N          iperf3 并发流数，默认 4
  --enable-shaping     auto 成功后，允许进入限速器扫描和整形候选流程
  --shape-rate MBIT    shape 使用的目标速率
  --no-install         不允许脚本安装 iperf3
  --dry-run            仅显示动作，不写入系统
  --yes                非交互确认（整形仍要求 --enable-shaping）

示例：
  sudo bash vps-tcp-tune.sh audit
  sudo bash vps-tcp-tune.sh auto --peer 203.0.113.10 --role proxy
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
memory_mib() { awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo; }
default_interface() { ip route show default 2>/dev/null | awk 'NR == 1 {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'; }
virtualization() { systemd-detect-virt 2>/dev/null || printf 'unknown'; }

validate_common() {
  case "$ROLE" in general|proxy|server) ;; *) fail '--role 只能是 general、proxy 或 server。' ;; esac
  is_positive_integer "$PEER_PORT" && (( PEER_PORT <= 65535 )) || fail '--port 必须是 1 到 65535 的整数。'
  is_positive_integer "$DURATION" && (( DURATION <= 120 )) || fail '--duration 必须是 1 到 120 的整数。'
  is_positive_integer "$WORKERS" && (( WORKERS <= 32 )) || fail '--workers 必须是 1 到 32 的整数。'
  [[ -z $BANDWIDTH_MBIT ]] || { is_positive_integer "$BANDWIDTH_MBIT" && (( BANDWIDTH_MBIT <= 100000 )) || fail '--bandwidth 必须是 1 到 100000 的整数。'; }
  [[ -z $RTT_MS ]] || { is_positive_integer "$RTT_MS" && (( RTT_MS <= 3000 )) || fail '--rtt 必须是 1 到 3000 的整数。'; }
}
validate_peer() { [[ -n $PEER ]] || fail '未取得可用 iperf3 对端。'; [[ $PEER =~ ^[A-Za-z0-9._-]+$ ]] || fail '--peer 仅允许域名或 IPv4 地址；IPv6 请用 DNS 名称。'; }

auto_pick_peer() {
  local candidate location provider rtt ranked host port probe
  local -a ports=(5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200)
  say '未指定 --peer，正在从内置公共 iperf3 节点中自动选择可用且 RTT 较低的对端。'
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
    (( rtt <= 250 )) || continue
    say "尝试公共节点：$location / $provider（RTT 约 ${rtt}ms）。"
    for port in "${ports[@]}"; do
      probe=$(timeout 12 iperf3 -c "$host" -p "$port" -P 1 -t 3 --omit 1 2>&1) || continue
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
  say "开始测试：对端=$PEER:$PEER_PORT，并发=$WORKERS，时长=${DURATION}s。"
  say '测试会产生实际流量；请确认套餐流量充足。'
  MEASURE_OUTPUT=$(timeout "$(( DURATION + 15 ))" iperf3 -c "$PEER" -p "$PEER_PORT" -P "$WORKERS" -t "$DURATION" --omit 2 2>&1) || { yellow "$MEASURE_OUTPUT"; printf '\n'; fail 'iperf3 测试失败；请检查对端、端口、防火墙和出口连通性。'; }
  parse_iperf_result "$MEASURE_OUTPUT" || { yellow "$MEASURE_OUTPUT"; printf '\n'; fail '无法解析 iperf3 输出，请使用官方 iperf3。'; }
  measure_rtt; line; say "实测接收吞吐：${MEASURE_RATE} Mbit/s"; say "发送端重传计数：${MEASURE_RETRANS}"; say "ping 平均 RTT：${MEASURE_RTT:-未取得} ms"; line
}

infer_bandwidth_from_nic() {
  local iface speed
  iface=$(default_interface); command -v ethtool >/dev/null 2>&1 || return 1
  speed=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/ {gsub(/Mb\/s/,"",$2);if($2~/^[0-9]+$/)print $2}')
  [[ -n $speed && $speed != -1 ]] || return 1; printf '%s' "$speed"
}
derive_network_facts() {
  [[ -n $BANDWIDTH_MBIT ]] || { [[ -n $MEASURE_RATE ]] && BANDWIDTH_MBIT=$MEASURE_RATE || BANDWIDTH_MBIT=$(infer_bandwidth_from_nic || true); }
  [[ -n $RTT_MS ]] || { [[ -n $MEASURE_RTT ]] && RTT_MS=$MEASURE_RTT; }
  is_positive_integer "$BANDWIDTH_MBIT" || fail '无法推导出口带宽；请提供 --bandwidth 或使用 --peer 测试。'
  is_positive_integer "$RTT_MS" || fail '无法取得 RTT；请提供 --rtt（例如中国方向常用 150）。'
}
calculate_buffer() {
  local bdp multiplier cap result memory
  memory=$(memory_mib); case "$ROLE" in proxy) multiplier=3 ;; *) multiplier=2 ;; esac
  bdp=$(( BANDWIDTH_MBIT * RTT_MS / 8 )); cap=$(( memory * 1024 * 1024 / 12 )); (( cap > 134217728 )) && cap=134217728
  result=$(( bdp * multiplier )); (( result < 4194304 )) && result=4194304; (( result > cap )) && result=$cap; (( result < 4194304 )) && result=4194304
  printf '%s' "$result"
}
calculate_backlog() { if (( BANDWIDTH_MBIT >= 5000 )); then printf 20000; elif (( BANDWIDTH_MBIT >= 1000 )); then printf 10000; elif (( BANDWIDTH_MBIT >= 200 )); then printf 5000; else printf 2500; fi; }

declare -a KEYS=() VALUES=()
add_setting() { sysctl_exists "$1" || { warn "内核不支持 $1，已跳过。"; return 0; }; KEYS+=("$1"); VALUES+=("$2"); }
build_settings() {
  local buffer backlog socket_queue syn_queue
  KEYS=(); VALUES=(); kernel_supports_bbr || fail '当前内核未提供 BBR；工具不会下载模块或替换内核。'
  buffer=$(calculate_buffer); backlog=$(calculate_backlog); case "$ROLE" in proxy|server) socket_queue=8192; syn_queue=8192 ;; *) socket_queue=4096; syn_queue=4096 ;; esac
  add_setting net.core.default_qdisc fq; add_setting net.ipv4.tcp_congestion_control bbr
  add_setting net.core.rmem_max "$buffer"; add_setting net.core.wmem_max "$buffer"
  add_setting net.ipv4.tcp_rmem "4096 131072 $buffer"; add_setting net.ipv4.tcp_wmem "4096 16384 $buffer"
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
  local i buffer; buffer=$(calculate_buffer); show_environment
  say "用途=$ROLE；带宽=${BANDWIDTH_MBIT} Mbit/s；RTT=${RTT_MS} ms；推导缓冲区=${buffer} 字节。"
  for i in "${!KEYS[@]}"; do say "${KEYS[$i]}：$(sysctl_value "${KEYS[$i]}") -> ${VALUES[$i]}"; done
  say '默认 qdisc 不会替换现有活动根队列；只有明确执行 shape 时才会改动它。'
}

snapshot_if_needed() {
  if [[ -e $CONFIG_FILE ]] && ! grep -Fqx "$MARKER" "$CONFIG_FILE"; then fail "拒绝覆盖非本工具配置：$CONFIG_FILE"; fi
  [[ -e $SNAPSHOT_FILE ]] && return 0; install -d -m 700 "$STATE_DIR"
  local tmp i; tmp=$(mktemp "$STATE_DIR/baseline.XXXXXX"); chmod 600 "$tmp"
  for i in "${!KEYS[@]}"; do printf '%s\t%s\n' "${KEYS[$i]}" "$(sysctl_value "${KEYS[$i]}")" >>"$tmp"; done; mv -f "$tmp" "$SNAPSHOT_FILE"
}
write_facts() {
  install -d -m 700 "$STATE_DIR"
  { printf 'role\t%s\n' "$ROLE"; printf 'bandwidth_mbit\t%s\n' "$BANDWIDTH_MBIT"; printf 'rtt_ms\t%s\n' "$RTT_MS"; printf 'peer\t%s\n' "$PEER"; printf 'measured_mbit\t%s\n' "${MEASURE_RATE:-}"; printf 'measured_retrans\t%s\n' "${MEASURE_RETRANS:-}"; } >"$FACTS_FILE"
  chmod 600 "$FACTS_FILE"
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
apply_tuning() {
  require_root; require_linux; require_command sysctl; require_command ip; require_command tc; lock; validate_common; derive_network_facts; build_settings; show_plan
  (( DRY_RUN )) && { ok '预览完成，未修改系统。'; return 0; }; confirm '将写入 sysctl、保存精确快照并立即应用自适应 TCP 参数。继续吗？' || { say '已取消。'; return 0; }
  snapshot_if_needed; local i
  for i in "${!KEYS[@]}"; do if ! sysctl -q -w "${KEYS[$i]}=${VALUES[$i]}"; then warn "${KEYS[$i]} 应用失败，正在恢复首次快照。"; restore_snapshot_values; fail '调优失败，已执行回滚。'; fi; done
  write_config; write_facts; ok "已应用 ${#KEYS[@]} 项自适应 TCP 设置。"
}

qdisc_root_kind() { tc qdisc show dev "$1" 2>/dev/null | awk 'NR==1 {print $2}'; }
qdisc_is_restorable() { case "$1" in fq|fq_codel|pfifo_fast|pfifo|bfifo) return 0 ;; *) return 1 ;; esac; }
write_shape_service() {
  local iface=$1 rate=$2 original=$3; install -d -m 700 "$STATE_DIR"; printf '%s\t%s\t%s\n' "$iface" "$rate" "$original" >"$SHAPE_STATE"; chmod 600 "$SHAPE_STATE"
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
  local iface original; iface=$(default_interface); [[ -n $iface ]] || fail '未检测到默认出口网卡。'; original=$(qdisc_root_kind "$iface"); qdisc_is_restorable "$original" || fail "当前根 qdisc=$original 不可安全恢复；为避免破坏多队列/特殊配置，拒绝整形。"
  line; warn "整形将暂时替换 $iface 的活动根 qdisc=$original，可能短暂影响连接。"; say "目标速率：${SHAPE_RATE} Mbit/s；叶子队列：FQ；重启后由 systemd 恢复。"; (( ENABLE_SHAPING )) || fail '整形必须显式加入 --enable-shaping。'
  (( DRY_RUN )) && { ok '整形预览完成，未修改系统。'; return 0; }; confirm '确认应用 HTB + FQ 出向整形吗？' || { say '已取消。'; return 0; }; write_shape_service "$iface" "$SHAPE_RATE" "$original"
  if ! apply_shape "$iface" "$SHAPE_RATE"; then
    warn '应用整形失败，正在移除本工具创建的持久化整形文件。'
    ASSUME_YES=1; unshape || true
    fail '整形失败，已尝试恢复根队列。'
  fi
  ok '出向整形已应用；请立即使用 verify 对比吞吐和重传。'
}
unshape() {
  require_root; require_linux; require_command tc; require_command systemctl; lock; [[ -f $SHAPE_STATE ]] || { say '未检测到本工具创建的整形。'; return 0; }
  local iface rate original; IFS=$'\t' read -r iface rate original <"$SHAPE_STATE"; qdisc_is_restorable "$original" || fail '整形状态损坏，拒绝猜测原始 qdisc。'
  (( DRY_RUN )) && { say "将恢复 $iface 的根 qdisc 为 $original。"; return 0; }; confirm "移除 ${rate}Mbit 整形并恢复 $original 吗？" || { say '已取消。'; return 0; }
  systemctl disable --now vps-tcp-safe-tuner-qdisc.service >/dev/null 2>&1 || true; rm -f "$SHAPE_UNIT" "$SHAPE_SCRIPT"; systemctl daemon-reload; tc qdisc replace dev "$iface" root "$original"; rm -f "$SHAPE_STATE"; ok '已移除本工具整形并恢复根 qdisc 类型。'
}
scan_shaper_candidate() {
  validate_peer; ensure_iperf3; require_command tc
  local nominal candidate output rate retrans best='' iface original
  iface=$(default_interface); [[ -n $iface ]] || fail '未检测到默认出口网卡。'
  original=$(qdisc_root_kind "$iface"); qdisc_is_restorable "$original" || fail "当前根 qdisc=$original 不可安全恢复，拒绝扫描整形。"
  nominal=$BANDWIDTH_MBIT; say "开始限速器候选扫描（最多 5 次，每次 ${DURATION}s）；仅使用可信对端。"
  confirm "扫描会暂时替换 $iface 的根 qdisc，可能短暂影响连接。继续吗？" || { say '已跳过扫描。'; return 0; }
  for candidate in 90 92 94 96 98; do
    SHAPE_RATE=$(( nominal * candidate / 100 ))
    apply_shape "$iface" "$SHAPE_RATE" || { tc qdisc replace dev "$iface" root "$original"; fail '扫描整形应用失败，已尝试恢复根队列。'; }
    output=$(timeout "$(( DURATION + 15 ))" iperf3 -c "$PEER" -p "$PEER_PORT" -P "$WORKERS" -t "$DURATION" --omit 2 2>&1) || { tc qdisc replace dev "$iface" root "$original"; continue; }
    tc qdisc replace dev "$iface" root "$original"
    parse_iperf_result "$output" || continue
    rate=$MEASURE_RATE; retrans=$MEASURE_RETRANS; say "候选 ${SHAPE_RATE}Mbit：吞吐 ${rate}Mbit，重传 ${retrans}。"; [[ $retrans == 0 ]] && best=$SHAPE_RATE
  done
  [[ -n $best ]] && say "建议整形速率候选：${best} Mbit/s；请比较 verify 后再手动执行 shape。" || warn '未得到零重传候选；不要盲目整形。'
}
auto() {
  require_root; require_linux; validate_common; measure; BANDWIDTH_MBIT=$MEASURE_RATE; [[ -n $MEASURE_RTT ]] && RTT_MS=$MEASURE_RTT; derive_network_facts; apply_tuning; say '正在执行调优后验证。'; measure
  if (( ENABLE_SHAPING )); then
    if [[ $MEASURE_RETRANS == 0 ]]; then say '验证无重传，跳过限速器扫描。';
    else warn '已启用限速器候选扫描。扫描只给出建议，不会持久化整形。'; scan_shaper_candidate; fi
  fi
}

audit() {
  require_linux; require_command sysctl; require_command ip; show_environment
  if kernel_supports_bbr; then say 'BBR 可用：是'; else say 'BBR 可用：否'; fi
  say "sysctl 配置目录：$([[ -d /etc/sysctl.d ]] && echo 可用 || echo 缺失)"; say "iperf3：$(command -v iperf3 >/dev/null 2>&1 && echo 已安装 || echo 未安装)"; say "systemd：$(command -v systemctl >/dev/null 2>&1 && echo 可用 || echo 不可用)"
  say '提示：OpenVZ/LXC 容器可能拒绝部分 sysctl 或 qdisc；脚本遇到拒绝会回滚。'
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
  [[ -f $SHAPE_STATE ]] && { ASSUME_YES=1; unshape; }; restore_snapshot_values; rm -f "$CONFIG_FILE" "$SNAPSHOT_FILE" "$FACTS_FILE"; rmdir "$STATE_DIR" 2>/dev/null || true; ok '已恢复快照并清理本工具创建的持久化文件。'
}
menu() {
  require_linux; line; say "VPS TCP 自适应调优器 v$VERSION"; line; yellow "1) 自适应测试并调优（需要可信 iperf3 对端）\n2) 按已知带宽/RTT 调优\n3) 仅检测\n4) 查看状态\n5) 回滚\n0) 退出\n"
  local choice; yellow '[选择] '; read -r choice
  case "$choice" in
    1) yellow '[对端域名或 IPv4，回车自动选择公共节点] '; read -r PEER; yellow '[用途 general/proxy/server，默认 general] '; read -r ROLE; ROLE=${ROLE:-general}; auto ;;
    2) yellow '[带宽 Mbit] '; read -r BANDWIDTH_MBIT; yellow '[典型 RTT ms] '; read -r RTT_MS; yellow '[用途 general/proxy/server，默认 general] '; read -r ROLE; ROLE=${ROLE:-general}; apply_tuning ;;
    3) audit ;; 4) status ;; 5) rollback ;; 0) say '已退出。' ;; *) fail '无效选择。' ;;
  esac
}
parse_options() {
  while (($#)); do case "$1" in
    --peer) PEER=${2:-}; shift 2 ;; --port) PEER_PORT=${2:-}; shift 2 ;; --role) ROLE=${2:-}; shift 2 ;; --bandwidth) BANDWIDTH_MBIT=${2:-}; shift 2 ;; --rtt) RTT_MS=${2:-}; shift 2 ;; --duration) DURATION=${2:-}; shift 2 ;; --workers) WORKERS=${2:-}; shift 2 ;; --shape-rate) SHAPE_RATE=${2:-}; shift 2 ;;
    --enable-shaping) ENABLE_SHAPING=1; shift ;; --dry-run) DRY_RUN=1; shift ;; --yes) ASSUME_YES=1; shift ;; --no-install) NO_INSTALL=1; shift ;; -h|--help) usage; exit 0 ;; *) fail "未知选项：$1" ;;
  esac; done
}
main() {
  COMMAND=${1:-menu}; shift || true; parse_options "$@"
  case "$COMMAND" in menu) menu ;; audit) audit ;; measure|verify) measure ;; auto) auto ;; apply) apply_tuning ;; shape) shape ;; unshape) unshape ;; status) status ;; rollback) rollback ;; help|-h|--help) usage ;; *) fail "未知命令：$COMMAND" ;; esac
}
main "$@"
