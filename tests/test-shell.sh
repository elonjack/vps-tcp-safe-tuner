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

parse_iperf_result '[SUM]   0.00-10.00  sec  1.10 GBytes   944 Mbits/sec    3             sender
[SUM]   0.00-10.00  sec  1.08 GBytes   928 Mbits/sec                  receiver'
assert_equals 928 "$MEASURE_RATE" 'iperf3 接收吞吐解析'
assert_equals 3 "$MEASURE_RETRANS" 'iperf3 重传解析'

tc() {
  if [[ $1 == qdisc && $2 == show ]]; then
    printf '%s\n' 'qdisc fq_codel 0: root refcnt 2 limit 2048p flows 512 target 5.0ms interval 100.0ms ecn'
  fi
}
snapshot=$(qdisc_snapshot eth0)
assert_equals $'fq_codel\tlimit 2048p flows 512 target 5.0ms interval 100.0ms ecn' "$snapshot" 'qdisc 参数快照'

printf 'Shell 功能测试通过。\n'
