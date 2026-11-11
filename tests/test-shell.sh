#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export VPS_TCP_TUNE_LIBRARY=1
# shellcheck source=../vps-tcp-tune.sh
source "$SCRIPT_DIR/../vps-tcp-tune.sh"

assert_equals() {
  local expected=$1 actual=$2 description=$3
  [[ $actual == "$expected" ]] || { printf '断言失败：%s；期望=%s，实际=%s\n' "$description" "$expected" "$actual" >&2; exit 1; }
}

assert_equals 1250 "$(rate_to_mbit 1.25 Gbits/sec)" 'Gbit 转 Mbit'
assert_equals 1 "$(rate_to_mbit 1000 Kbits/sec)" 'Kbit 转 Mbit'
assert_equals 1126 "$(transfer_to_mib 1.10 GBytes)" 'GBytes 转 MiB'
assert_equals 1024 "$(retrans_per_gib 1000 1000)" '按传输量归一化重传'

is_safe_iface eth0 || { printf '常规网卡名校验失败。\n' >&2; exit 1; }
is_safe_iface 'ens3.100' || { printf 'VLAN 网卡名校验失败。\n' >&2; exit 1; }
if is_safe_iface "eth0';touch /tmp/pwn"; then printf '危险网卡名未被拒绝。\n' >&2; exit 1; fi

export DURATION=12 MAX_TEST_GIB=1 ALLOW_HIGH_TRAFFIC=0
if guard_test_traffic '测试流量护栏' 10000 3 >/dev/null 2>&1; then printf '高流量护栏未生效。\n' >&2; exit 1; fi
export ALLOW_HIGH_TRAFFIC=1
guard_test_traffic '测试流量护栏' 10000 3 >/dev/null 2>&1 || { printf '显式高流量授权未生效。\n' >&2; exit 1; }
export MAX_TEST_GIB=20 ALLOW_HIGH_TRAFFIC=0

parse_options --peer-max-rtt 80 --max-test-gib 5 --max-rate-spread 35 --allow-public-peers --allow-high-traffic --forward-only
assert_equals 80 "$PEER_MAX_RTT" '公共节点 RTT 参数解析'
assert_equals 5 "$MAX_TEST_GIB" '流量上限参数解析'
assert_equals 35 "$MAX_RATE_SPREAD_PERCENT" '多轮波动阈值参数解析'
assert_equals 1 "$ALLOW_PUBLIC_PEERS" '公共节点显式授权参数解析'
assert_equals 1 "$ALLOW_HIGH_TRAFFIC" '高流量显式授权参数解析'
assert_equals 0 "$BIDIRECTIONAL" '仅出站参数解析'
export PEER_MAX_RTT=120 MAX_TEST_GIB=20 MAX_RATE_SPREAD_PERCENT=40 ALLOW_PUBLIC_PEERS=0 ALLOW_HIGH_TRAFFIC=0 BIDIRECTIONAL=1

export BANDWIDTH_MBIT=284
export RTT_MS=150
export ROLE=general
export BUFFER_MULTIPLIER_OVERRIDE=''
assert_equals 10650000 "$(calculate_buffer)" '跨境 150ms BDP 缓冲区推导'
export ROLE=proxy
assert_equals 10650000 "$(calculate_buffer)" '代理采用保守的 2× BDP 上限'
assert_equals 1048576 "$(calculate_initial_rmem "$(calculate_buffer)")" '代理初始接收缓冲区'
assert_equals 262144 "$(calculate_initial_wmem "$(calculate_buffer)")" '代理初始发送缓冲区'
export ROLE=general

parse_iperf_result '[SUM]   0.00-10.00  sec  1.10 GBytes   944 Mbits/sec    3             sender
[SUM]   0.00-10.00  sec  1.08 GBytes   928 Mbits/sec                  receiver'
assert_equals 928 "$MEASURE_RATE" 'iperf3 接收吞吐解析'
assert_equals 3 "$MEASURE_RETRANS" 'iperf3 重传解析'
assert_equals 1126 "$MEASURE_TRANSFER_MIB" 'iperf3 实际传输量解析'
assert_equals 'iperf3: error - the server is busy' "$(compact_iperf_error $'notice\niperf3: error - the server is busy\n')" 'iperf3 错误摘要'

MEASURE_FIXTURE=unstable TEST_INDEX=0
run_measure_iperf() {
  local -a rates retransfers transfers
  if [[ $MEASURE_FIXTURE == unstable ]]; then
    rates=(1450 2610 1550); retransfers=(2952 1451 2473); transfers=(2175 3915 2325)
  else
    rates=(1500 1550 1600); retransfers=(100 110 120); transfers=(2250 2325 2400)
  fi
  MEASURE_RATE=${rates[$TEST_INDEX]}; MEASURE_RETRANS=${retransfers[$TEST_INDEX]}; MEASURE_TRANSFER_MIB=${transfers[$TEST_INDEX]}
  TEST_INDEX=$(( TEST_INDEX + 1 ))
}
export ROUNDS=3 MAX_RATE_SPREAD_PERCENT=40
if measure_direction forward '出站' >/dev/null 2>&1; then printf '高波动基线未被拒绝。\n' >&2; exit 1; fi
[[ $MEASURE_FAILURE == *'波动'* ]] || { printf '高波动失败原因缺失。\n' >&2; exit 1; }
MEASURE_FIXTURE=stable TEST_INDEX=0
measure_direction forward '出站' >/dev/null 2>&1 || { printf '稳定基线被错误拒绝。\n' >&2; exit 1; }
assert_equals 1550 "$DIRECTION_RATE" '稳定样本中位吞吐'
assert_equals 6 "$DIRECTION_RATE_SPREAD" '稳定样本波动率'

tc() {
  if [[ $1 == class && $2 == show ]]; then
    printf '%s\n' 'class htb 1:10 root rate 200Mbit ceil 200Mbit burst 1600b cburst 1600b'
    return 0
  fi
  if [[ $1 == qdisc && $2 == show ]]; then
    if [[ ${TC_FIXTURE:-single} == mq ]]; then
      printf '%s\n' 'qdisc mq 0: root'
      printf '%s\n' 'qdisc fq 0: parent :1 limit 10000p pacing'
      printf '%s\n' 'qdisc fq_codel 0: parent :2 limit 2048p flows 512 target 5.0ms interval 100.0ms ecn'
    else
      printf '%s\n' 'qdisc fq_codel 0: root refcnt 2 limit 2048p flows 512 target 5.0ms interval 100.0ms ecn'
    fi
  fi
}
assert_equals 200Mbit "$(active_htb_rate eth0)" 'HTB 限速读取'
snapshot=$(qdisc_snapshot eth0)
assert_equals $'fq_codel\tlimit 2048p flows 512 target 5.0ms interval 100.0ms ecn' "$snapshot" 'qdisc 参数快照'

TC_FIXTURE=mq
mq_snapshot=$(mktemp)
snapshot=$(qdisc_snapshot eth0 "$mq_snapshot")
assert_equals $'mq\t'"$mq_snapshot" "$snapshot" 'mq 根队列快照'
assert_equals $'fq\t:1\tlimit 10000p pacing\nfq_codel\t:2\tlimit 2048p flows 512 target 5.0ms interval 100.0ms ecn' "$(cat "$mq_snapshot")" 'mq 叶子队列参数快照'
rm -f "$mq_snapshot"

policer_candidate_is_clean 950 1800 1000 0 || { printf '限速器干净候选判断失败。\n' >&2; exit 1; }
if policer_candidate_is_clean 800 0 1000 0; then printf '限速器送达率判断失败。\n' >&2; exit 1; fi
if ! is_material_regression 100 1000 100 4000; then printf '归一化重传恶化回滚判断失败。\n' >&2; exit 1; fi
if is_material_regression 100 1000 100 3500; then printf '归一化重传边界容差判断失败。\n' >&2; exit 1; fi
if ! is_material_regression 1550 1009 4660 85514; then printf '真实异常样本未触发回滚。\n' >&2; exit 1; fi
[[ $REGRESSION_REASON == *'85514 次/GiB'* ]] || { printf '回滚原因没有给出归一化重传数据。\n' >&2; exit 1; }
if ! is_material_regression 100 1000 80 1000; then printf '吞吐退化回滚判断失败。\n' >&2; exit 1; fi

printf 'Shell 功能测试通过。\n'
