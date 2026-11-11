#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'qdisc 集成测试需要 root。\n' >&2; exit 1; }
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export VPS_TCP_TUNE_LIBRARY=1
# shellcheck source=../vps-tcp-tune.sh
source "$SCRIPT_DIR/../vps-tcp-tune.sh"

iface="vqt$$"
cleanup() { ip link del "$iface" >/dev/null 2>&1 || true; }
trap cleanup EXIT

ip link add "$iface" type dummy
ip link set "$iface" up
tc qdisc replace dev "$iface" root fq_codel limit 2048 flows 512 target 5ms interval 100ms
snapshot=$(qdisc_snapshot "$iface")
IFS=$'\t' read -r original_kind original_spec <<<"$snapshot"
[[ $original_kind == fq_codel ]] || { printf '未取得 fq_codel 快照。\n' >&2; exit 1; }
[[ $original_spec == *'limit 2048p'* ]] || { printf '测试内核没有返回预期的 tc limit 显示格式。\n' >&2; exit 1; }

tc qdisc replace dev "$iface" root fq
restore_root_qdisc "$iface" "$original_kind" "$original_spec"
restored=$(tc qdisc show dev "$iface")
[[ $restored == *'qdisc fq_codel'* && $restored == *'limit 2048p'* ]] || {
  printf 'fq_codel 快照恢复后参数不一致：%s\n' "$restored" >&2
  exit 1
}

printf '真实 Linux qdisc 恢复测试通过。\n'
