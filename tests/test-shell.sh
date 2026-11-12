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
assert_equals 'limit 2048 flows 512 flow_limit 100 target 5.0ms interval 100.0ms' "$(normalize_qdisc_spec 'limit 2048p flows 512 flow_limit 100p target 5.0ms interval 100.0ms')" 'tc 显示参数规范化'

is_safe_iface eth0 || { printf '常规网卡名校验失败。\n' >&2; exit 1; }
is_safe_iface 'ens3.100' || { printf 'VLAN 网卡名校验失败。\n' >&2; exit 1; }
if is_safe_iface "eth0';touch /tmp/pwn"; then printf '危险网卡名未被拒绝。\n' >&2; exit 1; fi

export DURATION=12 MAX_TEST_GIB=1 ALLOW_HIGH_TRAFFIC=0
if guard_test_traffic '测试流量护栏' 10000 3 >/dev/null 2>&1; then printf '高流量护栏未生效。\n' >&2; exit 1; fi
export ALLOW_HIGH_TRAFFIC=1
guard_test_traffic '测试流量护栏' 10000 3 >/dev/null 2>&1 || { printf '显式高流量授权未生效。\n' >&2; exit 1; }
export MAX_TEST_GIB=20 ALLOW_HIGH_TRAFFIC=0

parse_options --peer-max-rtt 80 --max-test-gib 5 --max-rate-spread 35 --allow-public-peers --allow-high-traffic --forward-only --experiment-qdisc
assert_equals 80 "$PEER_MAX_RTT" '公共节点 RTT 参数解析'
assert_equals 5 "$MAX_TEST_GIB" '流量上限参数解析'
assert_equals 35 "$MAX_RATE_SPREAD_PERCENT" '多轮波动阈值参数解析'
assert_equals 1 "$ALLOW_PUBLIC_PEERS" '公共节点显式授权参数解析'
assert_equals 1 "$ALLOW_HIGH_TRAFFIC" '高流量显式授权参数解析'
assert_equals 0 "$BIDIRECTIONAL" '仅出站参数解析'
assert_equals 1 "$QDISC_EXPERIMENT" '活动 qdisc 实验参数解析'
export PEER_MAX_RTT=120 MAX_TEST_GIB=20 MAX_RATE_SPREAD_PERCENT=40 ALLOW_PUBLIC_PEERS=0 ALLOW_HIGH_TRAFFIC=0 BIDIRECTIONAL=1 QDISC_EXPERIMENT=0

export BANDWIDTH_MBIT=284
memory_mib() { printf 2048; }
export RTT_MS=150
export ROLE=general
export BUFFER_MULTIPLIER_OVERRIDE=''
assert_equals 12747152 "$(calculate_buffer)" '跨境 150ms BDP 缓冲区推导及余量'
export ROLE=proxy
assert_equals 12747152 "$(calculate_buffer)" '代理采用 2× BDP + 2MiB 上限'
assert_equals 67108864 "$(BANDWIDTH_MBIT=3000 RTT_MS=150 calculate_buffer)" '2GiB 内存单 socket 上限'
getconf() { printf 65536; }
assert_equals '2048 4096 8192' "$(calculate_tcp_mem)" '64KiB 页大小的 TCP 内存预算'
unset -f getconf
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
  case "$MEASURE_FIXTURE" in
    unstable) rates=(1450 2610 1550); retransfers=(2952 1451 2473); transfers=(2175 3915 2325) ;;
    one_outlier) rates=(109 132 149 39 115); retransfers=(4905 6805 1536 125 2219); transfers=(104 127 140 38 110) ;;
    noisy_majority) rates=(62 118 38 83 71); retransfers=(587 5558 369 1128 3155); transfers=(62 114 36 79 69) ;;
    chaotic) rates=(582 592 35 330 50); retransfers=(553 3569 0 556 530); transfers=(558 567 36 319 49) ;;
    *) rates=(1500 1550 1600); retransfers=(100 110 120); transfers=(2250 2325 2400) ;;
  esac
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
export ROUNDS=5 MEASURE_STAGE_TRANSFER_MIB=0
MEASURE_FIXTURE=one_outlier TEST_INDEX=0
measure_direction forward '出站' >/dev/null 2>&1 || { printf '五轮中单个离群样本未被安全剔除。\n' >&2; exit 1; }
assert_equals 115 "$DIRECTION_RATE" '离群过滤后的中位吞吐'
assert_equals 35 "$DIRECTION_RATE_SPREAD" '离群过滤后的波动率'
assert_equals 15465 "$DIRECTION_RETRANS" '离群轮重传未参与评分'
assert_equals 519 "$DIRECTION_TRANSFER_MIB" '离群轮实际流量仍计入总量'
MEASURE_FIXTURE=noisy_majority TEST_INDEX=0 MEASURE_STAGE_TRANSFER_MIB=0
measure_direction forward '出站' >/dev/null 2>&1 || { printf '五轮中多数稳定样本簇被错误拒绝。\n' >&2; exit 1; }
assert_equals 71 "$DIRECTION_RATE" '噪声线路多数簇中位吞吐'
assert_equals 30 "$DIRECTION_RATE_SPREAD" '噪声线路多数簇波动率'
assert_equals 4870 "$DIRECTION_RETRANS" '噪声线路离群轮重传未参与评分'
assert_equals 360 "$DIRECTION_TRANSFER_MIB" '噪声线路离群轮流量仍计入总量'
assert_equals 1 "$DIRECTION_NOISY" '噪声线路标记'
MEASURE_FIXTURE=chaotic TEST_INDEX=0 MEASURE_STAGE_TRANSFER_MIB=0
if measure_direction forward '出站' >/dev/null 2>&1; then printf '没有多数稳定簇的五轮样本被错误接受。\n' >&2; exit 1; fi
export ROUNDS=1 MAX_TEST_GIB=1 MEASURE_STAGE_TRANSFER_MIB=0
MEASURE_FIXTURE=stable TEST_INDEX=0
if measure_direction forward '出站' >/dev/null 2>&1; then printf '实际传输量运行中护栏未生效。\n' >&2; exit 1; fi
[[ $MEASURE_FAILURE == *'实际传输'* ]] || { printf '实际流量护栏失败原因缺失。\n' >&2; exit 1; }
export ROUNDS=3 MAX_TEST_GIB=20 MEASURE_STAGE_TRANSFER_MIB=0

tc() {
  if [[ $1 == class && $2 == show ]]; then
    printf '%s\n' 'class htb 1:10 root rate 200Mbit ceil 200Mbit burst 1600b cburst 1600b'
    return 0
  fi
  if [[ $1 == qdisc && $2 == show ]]; then
    if [[ ${TC_FIXTURE:-single} == mq || ${TC_FIXTURE:-single} == mq_fq ]]; then
      printf '%s\n' 'qdisc mq 0: root'
      printf '%s\n' 'qdisc fq 0: parent :1 limit 10000p pacing'
      if [[ ${TC_FIXTURE:-single} == mq_fq ]]; then printf '%s\n' 'qdisc fq 0: parent :2 limit 10000p pacing'
      else printf '%s\n' 'qdisc fq_codel 0: parent :2 limit 2048p flows 512 target 5.0ms interval 100.0ms ecn'; fi
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
if active_qdisc_is_fq eth0; then printf '混合 mq 叶子被误判为全 FQ。\n' >&2; exit 1; fi
TC_FIXTURE=mq_fq
active_qdisc_is_fq eth0 || { printf '全 FQ 的 mq 叶子未被识别。\n' >&2; exit 1; }

KEYS=(one two three); VALUES=(1 2 3)
set_setting_value two 22 || { printf '候选设置更新失败。\n' >&2; exit 1; }
assert_equals 22 "${VALUES[1]}" '候选设置值更新'
drop_setting two
assert_equals 'one three' "${KEYS[0]} ${KEYS[1]}" '候选设置删除'

export BIDIRECTIONAL=1
export NOISY_LINK=0
qdisc_candidate_is_better 100 1000 100 1000 106 1000 106 1000 || { printf '双向提升的 FQ 候选未被选择。\n' >&2; exit 1; }
if qdisc_candidate_is_better 100 1000 100 1000 120 1000 94 1000; then printf '单方向退化的 FQ 候选被错误选择。\n' >&2; exit 1; fi
if qdisc_candidate_is_better 100 1000 100 1000 106 4000 106 1000; then printf '高重传 FQ 候选被错误选择。\n' >&2; exit 1; fi
export NOISY_LINK=1
if qdisc_candidate_is_better 100 1000 100 1000 119 1000 119 1000; then printf '噪声线路未达 20%% 提升的 FQ 候选被错误选择。\n' >&2; exit 1; fi
qdisc_candidate_is_better 100 1000 100 1000 120 1000 120 1000 || { printf '噪声线路达到 20%% 提升的 FQ 候选未被选择。\n' >&2; exit 1; }
export NOISY_LINK=0

policer_candidate_is_clean 950 1800 1000 0 || { printf '限速器干净候选判断失败。\n' >&2; exit 1; }
if policer_candidate_is_clean 800 0 1000 0; then printf '限速器送达率判断失败。\n' >&2; exit 1; fi
if ! is_material_regression 100 1000 100 4000; then printf '归一化重传恶化回滚判断失败。\n' >&2; exit 1; fi
if is_material_regression 100 1000 100 3500; then printf '归一化重传边界容差判断失败。\n' >&2; exit 1; fi
if ! is_material_regression 1550 1009 4660 85514; then printf '真实异常样本未触发回滚。\n' >&2; exit 1; fi
[[ $REGRESSION_REASON == *'85514 次/GiB'* ]] || { printf '回滚原因没有给出归一化重传数据。\n' >&2; exit 1; }
if ! is_material_regression 100 1000 80 1000; then printf '吞吐退化回滚判断失败。\n' >&2; exit 1; fi
candidate_retrans_is_acceptable 1000 2500 || { printf '相对基线重传边界被错误拒绝。\n' >&2; exit 1; }
if candidate_retrans_is_acceptable 1000 2501; then printf '超过相对基线重传边界的候选被错误接受。\n' >&2; exit 1; fi
candidate_retrans_is_acceptable 30000 60000 || { printf '高损耗基线的相对候选被错误拒绝。\n' >&2; exit 1; }

printf 'Shell 功能测试通过。\n'
