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

BANDWIDTH_MBIT=284
RTT_MS=150
ROLE=general
BUFFER_MULTIPLIER_OVERRIDE=''
assert_equals 10650000 "$(calculate_buffer)" '跨境 150ms BDP 缓冲区推导'

parse_iperf_result '[SUM]   0.00-10.00  sec  1.10 GBytes   944 Mbits/sec    3             sender
[SUM]   0.00-10.00  sec  1.08 GBytes   928 Mbits/sec                  receiver'
assert_equals 928 "$MEASURE_RATE" 'iperf3 接收吞吐解析'
assert_equals 3 "$MEASURE_RETRANS" 'iperf3 重传解析'

tc() {
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
snapshot=$(qdisc_snapshot eth0)
assert_equals $'fq_codel\tlimit 2048p flows 512 target 5.0ms interval 100.0ms ecn' "$snapshot" 'qdisc 参数快照'

TC_FIXTURE=mq
mq_snapshot=$(mktemp)
snapshot=$(qdisc_snapshot eth0 "$mq_snapshot")
assert_equals $'mq\t'"$mq_snapshot" "$snapshot" 'mq 根队列快照'
assert_equals $'fq\t:1\tlimit 10000p pacing\nfq_codel\t:2\tlimit 2048p flows 512 target 5.0ms interval 100.0ms ecn' "$(cat "$mq_snapshot")" 'mq 叶子队列参数快照'
rm -f "$mq_snapshot"

policer_candidate_is_clean 950 8 1000 0 || { printf '限速器干净候选判断失败。\n' >&2; exit 1; }
if policer_candidate_is_clean 800 0 1000 0; then printf '限速器送达率判断失败。\n' >&2; exit 1; fi

printf 'Shell 功能测试通过。\n'
