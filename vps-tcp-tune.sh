#!/usr/bin/env bash
# vps-tcp-safe-tuner: 可审计、可回滚的 Linux VPS TCP 调优工具。
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly PROGRAM='vps-tcp-tune'
readonly VERSION='1.0.0'
readonly STATE_DIR='/var/lib/vps-tcp-safe-tuner'
readonly SNAPSHOT_FILE="$STATE_DIR/baseline.tsv"
readonly CONFIG_FILE='/etc/sysctl.d/99-vps-tcp-safe-tuner.conf'
readonly LOCK_FILE='/run/lock/vps-tcp-safe-tuner.lock'
readonly MARKER='# Managed by vps-tcp-safe-tuner. Remove only with vps-tcp-tune rollback.'

PROFILE='safe'
BANDWIDTH_MBIT=''
RTT_MS=''
DRY_RUN=0
ASSUME_YES=0

yellow() {
  if [[ -t 1 ]]; then printf '\033[1;33m%s\033[0m' "$*"; else printf '%s' "$*"; fi
}

say() { yellow "[信息] $*"; printf '\n'; }
warn() { yellow "[警告] $*" >&2; printf '\n' >&2; }
fail() { yellow "[错误] $*" >&2; printf '\n' >&2; exit 1; }
ok() { yellow "[完成] $*"; printf '\n'; }
line() { yellow '------------------------------------------------------------'; printf '\n'; }

usage() {
  yellow "$(cat <<'EOF'
vps-tcp-tune - 安全、可回滚的 Linux VPS TCP 调优工具

用法：
  sudo bash vps-tcp-tune.sh apply [选项]      应用调优（默认安全档）
  sudo bash vps-tcp-tune.sh status            查看当前状态
  sudo bash vps-tcp-tune.sh preview [选项]    只预览，不改系统
  sudo bash vps-tcp-tune.sh rollback          按首次快照恢复
  sudo bash vps-tcp-tune.sh help              显示帮助

选项：
  --profile safe|throughput  safe：仅 BBR/FQ；throughput：按 BDP 调整缓冲区
  --bandwidth MBIT           标称出口带宽（throughput 必填，例如 1000）
  --rtt MS                   典型目标 RTT（throughput 必填，例如 150）
  --dry-run                  显示将执行的操作，不改系统
  --yes                      非交互确认；请仅在已阅读 preview 后使用

示例：
  sudo bash vps-tcp-tune.sh preview
  sudo bash vps-tcp-tune.sh apply
  sudo bash vps-tcp-tune.sh apply --profile throughput --bandwidth 1000 --rtt 150
  sudo bash vps-tcp-tune.sh rollback
EOF
)"
  printf '\n'
}

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail '需要 root 权限，请使用 sudo 执行。'; }
require_linux() { [[ $(uname -s) == Linux ]] || fail '仅支持 Linux 内核。'; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "缺少必要命令：$1"; }

is_positive_integer() { [[ $1 =~ ^[1-9][0-9]*$ ]]; }

confirm() {
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || fail '非交互执行必须显式添加 --yes，建议先运行 preview。'
  local answer
  yellow '[确认] 上述操作会修改 TCP 内核参数并写入 /etc/sysctl.d。继续吗？[y/N] '
  read -r answer
  [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
}

lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  require_command flock
  exec 9>"$LOCK_FILE"
  flock -n 9 || fail '已有一个本工具实例正在运行；为避免并发修改，已退出。'
}

sysctl_value() { sysctl -n "$1" 2>/dev/null || true; }
sysctl_exists() {
  # 不使用 `sysctl | grep -q`：grep 提前退出会让写端收到 SIGPIPE，
  # 在 pipefail 下可能把“存在”误判为失败。
  local names
  names=$(sysctl -aN 2>/dev/null || true)
  [[ $'\n'$names$'\n' == *$'\n'"$1"$'\n'* ]]
}

kernel_supports_bbr() {
  local available
  available=$(sysctl_value net.ipv4.tcp_available_congestion_control)
  [[ " $available " == *' bbr '* ]]
}

memory_mib() {
  awk '/MemTotal:/ { print int($2 / 1024) }' /proc/meminfo
}

default_interface() {
  ip route show default 2>/dev/null | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

validate_profile() {
  case "$PROFILE" in
    safe) ;;
    throughput)
      is_positive_integer "$BANDWIDTH_MBIT" || fail 'throughput 档必须给出正整数 --bandwidth。'
      is_positive_integer "$RTT_MS" || fail 'throughput 档必须给出正整数 --rtt。'
      (( BANDWIDTH_MBIT <= 100000 && RTT_MS <= 2000 )) || fail '带宽须不超过 100000 Mbit，RTT 须不超过 2000 ms。'
      (( $(memory_mib) >= 512 )) || fail 'throughput 档至少需要 512 MiB 内存；请使用 safe 档。'
      ;;
    *) fail 'profile 只能是 safe 或 throughput。' ;;
  esac
}

# 高吞吐档的单 socket 最大缓冲区：2×BDP，限制在 4 MiB 到 min(64 MiB, 内存/16)。
# 这样不套用固定大数，也不会把小内存 VPS 的每连接上限无限放大。
calculated_buffer_bytes() {
  local bdp cap ram result
  bdp=$(( BANDWIDTH_MBIT * RTT_MS / 8 ))
  cap=$(( $(memory_mib) * 1024 * 1024 / 16 ))
  (( cap > 67108864 )) && cap=67108864
  result=$(( bdp * 2 ))
  (( result < 4194304 )) && result=4194304
  (( result > cap )) && result=$cap
  (( result < 4194304 )) && result=4194304
  printf '%s' "$result"
}

declare -a KEYS=()
declare -a VALUES=()

add_setting() {
  local key=$1 value=$2
  sysctl_exists "$key" || { warn "内核不支持 $key，已跳过。"; return 0; }
  KEYS+=("$key")
  VALUES+=("$value")
}

build_settings() {
  KEYS=()
  VALUES=()
  kernel_supports_bbr || fail '当前内核未提供 BBR；为避免加载内核模块或安装软件，本工具不会继续。'
  add_setting net.core.default_qdisc fq
  add_setting net.ipv4.tcp_congestion_control bbr

  if [[ $PROFILE == throughput ]]; then
    local buffer
    buffer=$(calculated_buffer_bytes)
    add_setting net.core.rmem_max "$buffer"
    add_setting net.core.wmem_max "$buffer"
    add_setting net.ipv4.tcp_rmem "4096 131072 $buffer"
    add_setting net.ipv4.tcp_wmem "4096 16384 $buffer"
    add_setting net.ipv4.tcp_mtu_probing 1
    add_setting net.ipv4.tcp_slow_start_after_idle 0
  fi
  ((${#KEYS[@]} > 0)) || fail '没有可写入的调优项。'
}

show_environment() {
  local iface mem
  iface=$(default_interface)
  mem=$(memory_mib)
  line
  say "工具版本：$VERSION"
  say "内核版本：$(uname -r)"
  say "内存：${mem} MiB"
  say "默认网卡：${iface:-未检测到}"
  say "当前拥塞控制：$(sysctl_value net.ipv4.tcp_congestion_control)"
  say "当前默认队列：$(sysctl_value net.core.default_qdisc)"
  if [[ -n $iface ]]; then
    say "活动根队列：$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR == 1 { print $2 }')"
  fi
  line
}

show_plan() {
  local i buffer=''
  show_environment
  yellow "[计划] profile=$PROFILE"
  printf '\n'
  if [[ $PROFILE == throughput ]]; then
    buffer=$(calculated_buffer_bytes)
    yellow "[计划] 带宽=${BANDWIDTH_MBIT} Mbit，RTT=${RTT_MS} ms，推导单连接缓冲区上限=${buffer} 字节"
    printf '\n'
  fi
  for i in "${!KEYS[@]}"; do
    yellow "[计划] ${KEYS[$i]}: $(sysctl_value "${KEYS[$i]}") -> ${VALUES[$i]}"
    printf '\n'
  done
  line
  yellow '[说明] 本工具不会：安装软件包、下载/执行远程代码、创建 swap、修改防火墙、修改路由、替换活动网卡 qdisc、配置 tc 限速。'
  printf '\n'
  yellow '[说明] default_qdisc=fq 在新建网络设备或重启后生效；为避免打断现有连接，脚本不替换当前活动 qdisc。'
  printf '\n'
}

snapshot_if_needed() {
  if [[ -e $CONFIG_FILE ]] && ! grep -Fqx "$MARKER" "$CONFIG_FILE"; then
    fail "拒绝覆盖非本工具生成的配置：$CONFIG_FILE"
  fi
  if [[ -e $SNAPSHOT_FILE ]]; then
    [[ -f $CONFIG_FILE ]] || fail "发现历史快照 $SNAPSHOT_FILE，但配置文件不存在；拒绝覆盖未知状态，请先检查并人工恢复。"
    return 0
  fi
  install -d -m 700 "$STATE_DIR"
  local tmp i
  tmp=$(mktemp "$STATE_DIR/baseline.XXXXXX")
  chmod 600 "$tmp"
  for i in "${!KEYS[@]}"; do
    printf '%s\t%s\n' "${KEYS[$i]}" "$(sysctl_value "${KEYS[$i]}")" >>"$tmp"
  done
  mv -f "$tmp" "$SNAPSHOT_FILE"
}

restore_snapshot_values() {
  local key value
  [[ -f $SNAPSHOT_FILE ]] || return 0
  while IFS=$'\t' read -r key value; do
    [[ -n $key ]] || continue
    sysctl_exists "$key" && sysctl -q -w "$key=$value" || warn "恢复 $key 失败，可能已不受当前内核支持。"
  done <"$SNAPSHOT_FILE"
}

write_config() {
  local tmp i
  tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
  chmod 644 "$tmp"
  {
    printf '%s\n' "$MARKER"
    printf '# profile=%s; generated=%s\n' "$PROFILE" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for i in "${!KEYS[@]}"; do printf '%s = %s\n' "${KEYS[$i]}" "${VALUES[$i]}"; done
  } >"$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

apply() {
  require_root
  require_linux
  require_command sysctl
  require_command ip
  lock
  validate_profile
  build_settings
  show_plan
  (( DRY_RUN )) && { ok '预览完成，未修改系统。'; return 0; }
  confirm || { say '已取消，未修改系统。'; return 0; }

  snapshot_if_needed
  local i applied=0
  for i in "${!KEYS[@]}"; do
    if ! sysctl -q -w "${KEYS[$i]}=${VALUES[$i]}"; then
      warn "应用 ${KEYS[$i]} 失败，正在按快照回滚本次变更。"
      restore_snapshot_values
      fail '调优未完成，系统已尝试恢复到首次快照。'
    fi
    ((applied+=1))
  done
  (( applied == ${#KEYS[@]} )) || fail '内部错误：应用数量不一致。'
  write_config
  ok "已应用 $PROFILE 档调优，并写入 $CONFIG_FILE。"
  say "已保存首次快照：$SNAPSHOT_FILE"
  say '建议在业务低峰重启后检查 status，以确认默认 FQ 队列已生效。'
}

status() {
  require_linux
  require_command sysctl
  show_environment
  if [[ -f $CONFIG_FILE ]]; then
    ok "检测到本工具配置：$CONFIG_FILE"
    yellow "[配置] $(sed -n '1,20p' "$CONFIG_FILE")"
    printf '\n'
  else
    warn '未检测到本工具的持久化配置。'
  fi
  [[ -f $SNAPSHOT_FILE ]] && say "可回滚快照：$SNAPSHOT_FILE" || say '未检测到可回滚快照。'
}

rollback() {
  require_root
  require_linux
  require_command sysctl
  lock
  [[ -f $SNAPSHOT_FILE ]] || fail "未找到快照：$SNAPSHOT_FILE；本工具不会猜测原始系统值。"
  if [[ -e $CONFIG_FILE ]] && ! grep -Fqx "$MARKER" "$CONFIG_FILE"; then
    fail "拒绝删除非本工具生成的配置：$CONFIG_FILE"
  fi
  line
  say "将按首次快照恢复 $(wc -l <"$SNAPSHOT_FILE") 个内核参数。"
  say "将删除本工具配置：$CONFIG_FILE"
  line
  (( DRY_RUN )) && { ok '预览完成，未修改系统。'; return 0; }
  confirm || { say '已取消，未修改系统。'; return 0; }
  restore_snapshot_values
  rm -f "$CONFIG_FILE"
  rm -f "$SNAPSHOT_FILE"
  rmdir "$STATE_DIR" 2>/dev/null || true
  ok '已恢复快照并移除本工具的持久化配置。'
}

parse_options() {
  while (($#)); do
    case "$1" in
      --profile) PROFILE=${2:-}; shift 2 ;;
      --bandwidth) BANDWIDTH_MBIT=${2:-}; shift 2 ;;
      --rtt) RTT_MS=${2:-}; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "未知选项：$1" ;;
    esac
  done
}

main() {
  local command=${1:-help}
  shift || true
  case "$command" in
    apply) parse_options "$@"; apply ;;
    preview) DRY_RUN=1; parse_options "$@"; require_linux; require_command sysctl; validate_profile; build_settings; show_plan; ok '预览完成，未修改系统。' ;;
    status) (($# == 0)) || fail 'status 不接受选项。'; status ;;
    rollback) parse_options "$@"; rollback ;;
    help|-h|--help) usage ;;
    *) fail "未知命令：$command；请使用 help 查看帮助。" ;;
  esac
}

main "$@"
