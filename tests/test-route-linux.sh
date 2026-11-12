#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export VPS_TCP_TUNE_LIBRARY=1
# shellcheck source=../vps-tcp-tune.sh
source "$SCRIPT_DIR/../vps-tcp-tune.sh"
namespace="vqroute$$"
cleanup() { command ip netns del "$namespace" >/dev/null 2>&1 || true; }
trap cleanup EXIT
command ip netns add "$namespace"
ip() { command ip -n "$namespace" "$@"; }
ip link add test0 type dummy
ip link set test0 up
ip addr add 192.0.2.1/24 dev test0
ip -4 route add default via 192.0.2.2 dev test0 metric 123 initcwnd 20 initrwnd 24
before=$(ip -4 route show default)
route_with_windows "$before" 32 32
after=$(ip -4 route show default)
[[ $(route_field initcwnd "$after") == 32 && $(route_field initrwnd "$after") == 32 ]]
[[ $(route_field metric "$after") == 123 && $(route_field via "$after") == 192.0.2.2 ]]
ip -4 route change default via 192.0.2.3 dev test0 metric 123
route_with_windows "$(ip -4 route show default)" "$(route_field initcwnd "$before")" "$(route_field initrwnd "$before")"
after=$(ip -4 route show default)
[[ $(route_field via "$after") == 192.0.2.3 && $(route_field initcwnd "$after") == 20 && $(route_field initrwnd "$after") == 24 ]]
route_with_windows "$after" 0 0
after=$(ip -4 route show default)
[[ -z $(route_field initcwnd "$after") && -z $(route_field initrwnd "$after") ]]
if route_with_windows $'default dev test0\ndefault dev test1' 32 32; then exit 1; fi
if route_with_windows 'default nexthop via 192.0.2.2 dev test0 weight 1' 32 32; then exit 1; fi
printf '隔离网络初始窗口应用、网关变更与恢复测试通过。\n'
