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
assert_equals 85 "$(estimate_wizard_traffic_gib 3000)" '三千兆一键流程约八十GiB级上限'

is_safe_iface eth0 || { printf '常规网卡名校验失败。\n' >&2; exit 1; }
is_safe_iface 'ens3.100' || { printf 'VLAN 网卡名校验失败。\n' >&2; exit 1; }
if is_safe_iface "eth0';touch /tmp/pwn"; then printf '危险网卡名未被拒绝。\n' >&2; exit 1; fi

export DURATION=12 MAX_TEST_GIB=1 ALLOW_HIGH_TRAFFIC=0
if guard_test_traffic '测试流量护栏' 10000 3 >/dev/null 2>&1; then printf '高流量护栏未生效。\n' >&2; exit 1; fi
export ALLOW_HIGH_TRAFFIC=1
guard_test_traffic '测试流量护栏' 10000 3 >/dev/null 2>&1 || { printf '显式高流量授权未生效。\n' >&2; exit 1; }
export MAX_TEST_GIB=20 ALLOW_HIGH_TRAFFIC=0

parse_options --peer-max-rtt 80 --max-test-gib 5 --max-rate-spread 35 --allow-public-peers --allow-high-traffic --allow-sysctl-conflicts --forward-only --experiment-qdisc
assert_equals 80 "$PEER_MAX_RTT" '公共节点 RTT 参数解析'
assert_equals 5 "$MAX_TEST_GIB" '流量上限参数解析'
assert_equals 35 "$MAX_RATE_SPREAD_PERCENT" '多轮波动阈值参数解析'
assert_equals 1 "$ALLOW_PUBLIC_PEERS" '公共节点显式授权参数解析'
assert_equals 1 "$ALLOW_HIGH_TRAFFIC" '高流量显式授权参数解析'
assert_equals 1 "$ALLOW_SYSCTL_CONFLICTS" 'sysctl 冲突显式授权参数解析'
assert_equals 0 "$BIDIRECTIONAL" '仅出站参数解析'
assert_equals 1 "$QDISC_EXPERIMENT" '活动 qdisc 实验参数解析'
export PEER_MAX_RTT=120 MAX_TEST_GIB=20 MAX_RATE_SPREAD_PERCENT=40 ALLOW_PUBLIC_PEERS=0 ALLOW_HIGH_TRAFFIC=0 ALLOW_SYSCTL_CONFLICTS=0 BIDIRECTIONAL=1 QDISC_EXPERIMENT=0

export BANDWIDTH_MBIT=284
memory_mib() { printf 2048; }
export RTT_MS=150
export ROLE=general
export BUFFER_MULTIPLIER_OVERRIDE=''
export BUFFER_BANDWIDTH_MBIT=''
assert_equals 12747152 "$(calculate_buffer)" '跨境 150ms BDP 缓冲区推导及余量'
export ROLE=proxy
assert_equals 12747152 "$(calculate_buffer)" '代理采用 2× BDP + 2MiB 上限'
assert_equals 67108864 "$(BANDWIDTH_MBIT=3000 RTT_MS=150 calculate_buffer)" '2GiB 内存单 socket 上限'
assert_equals 3000 "$(estimate_buffer_bandwidth 1664)" '自动测速容量预留并向上取三千兆档位'
assert_equals 1000 "$(estimate_buffer_bandwidth 600)" '自动测速容量预留并向上取千兆档位'
export BUFFER_BANDWIDTH_MBIT=3000
assert_equals 67108864 "$(calculate_buffer)" '自动容量档位仍受内存预算限制'
memory_mib() { printf 8192; }
assert_equals 114597152 "$(calculate_buffer)" '三千兆/150ms 自动容量得到约 109.3MiB 窗口'
memory_mib() { printf 2048; }
export BUFFER_BANDWIDTH_MBIT=''
getconf() { printf 65536; }
assert_equals '2048 4096 8192' "$(calculate_tcp_mem)" '64KiB 页大小的 TCP 内存预算'
unset -f getconf
assert_equals 1048576 "$(calculate_initial_rmem "$(calculate_buffer)")" '代理初始接收缓冲区'
assert_equals 1048576 "$(calculate_initial_wmem "$(calculate_buffer)")" '代理初始发送缓冲区'
assert_equals 16384 "$(calculate_backlog)" '常规带宽软中断积压队列'
assert_equals 32768 "$(BANDWIDTH_MBIT=5000 calculate_backlog)" '五千兆以上软中断积压队列'

sysctl_exists() { return 0; }
build_settings
setting_value() {
  local wanted=$1 index
  for index in "${!KEYS[@]}"; do [[ ${KEYS[$index]} == "$wanted" ]] && { printf '%s' "${VALUES[$index]}"; return 0; }; done
  return 1
}
assert_equals 1 "$(setting_value net.ipv4.tcp_sack)" '显式恢复 SACK'
assert_equals 1 "$(setting_value net.ipv4.tcp_dsack)" '显式恢复 DSACK'
assert_equals 1 "$(setting_value net.ipv4.tcp_timestamps)" '显式恢复 TCP timestamps'
assert_equals 0 "$(setting_value net.ipv4.tcp_no_metrics_save)" '恢复 TCP 路由指标缓存'
assert_equals 3 "$(setting_value net.ipv4.tcp_early_retrans)" '恢复 TLP 尾丢包探测'
assert_equals 1 "$(setting_value net.ipv4.tcp_recovery)" '恢复 RACK 丢包检测'
assert_equals 3 "$(setting_value net.ipv4.tcp_reordering)" '撤销激进固定重排序阈值'
assert_equals 3 "$(setting_value net.ipv4.tcp_fastopen)" '启用客户端与服务端 Fast Open 能力'
assert_equals 600 "$(setting_value net.core.netdev_budget)" '提高软中断单轮预算'
unset -f sysctl_exists setting_value
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

assert_equals '4096 131072 4194304' "$(normalize_sysctl_value $'4096\t131072   4194304')" 'sysctl 值空白规范化'

conflict_dir=$(mktemp -d)
printf '%s\n' 'net.ipv4.tcp_congestion_control = cubic' 'net.ipv4.ip_forward = 1' >"$conflict_dir/50-old.conf"
printf '%s\n' 'net.core.default_qdisc=fq_codel' >"$conflict_dir/99-other.conf"
SYSCTL_CONFIG_FILES_OVERRIDE=$(printf '%s\n%s' "$conflict_dir/50-old.conf" "$conflict_dir/99-other.conf")
conflicts=$(find_sysctl_conflicts net.ipv4.tcp_congestion_control net.core.default_qdisc)
[[ $conflicts == *$'50-old.conf\tnet.ipv4.tcp_congestion_control\tcubic'* ]] || { printf '未检测到拥塞算法配置冲突。\n' >&2; exit 1; }
[[ $conflicts == *$'99-other.conf\tnet.core.default_qdisc\tfq_codel'* ]] || { printf '未检测到 qdisc 配置冲突。\n' >&2; exit 1; }
report_sysctl_conflicts net.ipv4.tcp_congestion_control net.core.default_qdisc >/dev/null 2>&1 || { printf '排序更早的 sysctl 文件被错误阻断。\n' >&2; exit 1; }
printf '%s\n' 'net.core.default_qdisc = cake' >"$conflict_dir/zz-after.conf"
SYSCTL_CONFIG_FILES_OVERRIDE+=$'\n'"$conflict_dir/zz-after.conf"
if report_sysctl_conflicts net.core.default_qdisc >/dev/null 2>&1; then printf '排序更晚的 sysctl 文件未被阻断。\n' >&2; exit 1; fi
ALLOW_SYSCTL_CONFLICTS=1
report_sysctl_conflicts net.core.default_qdisc >/dev/null 2>&1 || { printf '显式授权未放行排序更晚的 sysctl 文件。\n' >&2; exit 1; }
ALLOW_SYSCTL_CONFLICTS=0
unset SYSCTL_CONFIG_FILES_OVERRIDE
rm -rf "$conflict_dir"

SYSCTL_ONE=1; SYSCTL_TWO='2 3'
sysctl() {
  if [[ $1 == -n ]]; then
    case "$2" in one) printf '%s\n' "$SYSCTL_ONE" ;; two) printf '%s\n' "$SYSCTL_TWO" ;; *) return 1 ;; esac
  elif [[ $1 == -aN ]]; then printf 'one\ntwo\n';
  elif [[ $1 == -q && $2 == -w ]]; then
    case "$3" in one=*) SYSCTL_ONE=${3#*=} ;; two=*) SYSCTL_TWO=${3#*=} ;; *) return 1 ;; esac
  else return 1
  fi
}
KEYS=(one two); VALUES=(1 '2 3')
verify_built_settings || { printf '正确写入值未通过读回验证。\n' >&2; exit 1; }
VALUES=(1 '2 4')
if verify_built_settings >/dev/null 2>&1; then printf '错误写入值未被读回验证发现。\n' >&2; exit 1; fi
apply_built_settings || { printf '设置应用计数测试写入失败。\n' >&2; exit 1; }
assert_equals 1 "$APPLIED_CHANGED_COUNT" '实际改变设置计数'
assert_equals 1 "$APPLIED_UNCHANGED_COUNT" '原本一致设置计数'
verify_built_settings || { printf '设置应用计数测试写入后验证失败。\n' >&2; exit 1; }
unset -f sysctl

# 自适应扫描应先单轮探测，疑似拐点才多轮复核，并恢复调用方轮数。
PROBE_CALLS=0; PROBE_ROUNDS=''
probe_shaper_candidate() {
  PROBE_CALLS=$(( PROBE_CALLS + 1 )); PROBE_ROUNDS+="${PROBE_ROUNDS:+,}${ROUNDS}"
  (( PROBE_CALLS > 1 ))
}
export ROUNDS=3 POLICER_ROUNDS=3
probe_adaptive_shaper_candidate eth0 fq '' 1000 0 || { printf '自适应拐点复核测试失败。\n' >&2; exit 1; }
assert_equals 2 "$PROBE_CALLS" '疑似拐点触发一次多轮复核'
assert_equals '1,3' "$PROBE_ROUNDS" '粗扫单轮、疑点三轮'
assert_equals 3 "$ROUNDS" '自适应探测后恢复调用方轮数'

# 五阶段向导必须按顺序调用基础调优、40%路径检测和整形扫描/复测。
WIZARD_TUNE_CALLS=0; WIZARD_PATH_CALLS=0; WIZARD_SHAPER_CALLS=0
require_root() { :; }; require_linux() { :; }; ensure_iperf3() { :; }; validate_peer() { :; }
guard_test_traffic() { return 0; }; confirm() { return 0; }; confirm_default_yes() { return 0; }
tune() { WIZARD_TUNE_CALLS=$(( WIZARD_TUNE_CALLS + 1 )); export TUNING_APPLIED=1; }
path_quality_check() { WIZARD_PATH_CALLS=$(( WIZARD_PATH_CALLS + 1 )); }
tune_shaper() { WIZARD_SHAPER_CALLS=$(( WIZARD_SHAPER_CALLS + 1 )); }
export BANDWIDTH_MBIT=1000 BUFFER_BANDWIDTH_MBIT='' RTT_MS='' ROLE=proxy PEER=trusted.example PEER_PORT=5201 BIDIRECTIONAL=1 ASSUME_YES=0 WIZARD_MODE=0 ENABLE_SHAPING=0 MENU_MODE=0 MAX_TEST_GIB=50 ALLOW_HIGH_TRAFFIC=0
wizard >/dev/null
assert_equals 1 "$WIZARD_TUNE_CALLS" '五阶段向导调用基础调优'
assert_equals 1 "$WIZARD_PATH_CALLS" '五阶段向导调用路径质量检测'
assert_equals 1 "$WIZARD_SHAPER_CALLS" '五阶段向导调用整形扫描和复测'
assert_equals 0 "$WIZARD_MODE" '五阶段向导完成后恢复模式标记'

# 菜单1高带宽只做一次总确认；确认后直接完成五阶段，并把总确认视为本次流量授权。
WIZARD_TUNE_CALLS=0; WIZARD_PATH_CALLS=0; WIZARD_SHAPER_CALLS=0
export MENU_MODE=1 ALLOW_HIGH_TRAFFIC=0 TUNING_APPLIED=0 BANDWIDTH_MBIT=3000 MAX_TEST_GIB=50
wizard >/dev/null
assert_equals 1 "$WIZARD_TUNE_CALLS" '菜单高带宽确认后调用基础调优'
assert_equals 1 "$WIZARD_PATH_CALLS" '菜单高带宽确认后调用路径检测'
assert_equals 1 "$WIZARD_SHAPER_CALLS" '菜单高带宽确认后调用扫描和复测'
assert_equals 1 "$ALLOW_HIGH_TRAFFIC" '菜单总确认作为本次高流量授权'

printf 'Shell 功能测试通过。\n'
