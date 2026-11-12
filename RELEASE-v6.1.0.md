补齐基础调优的内存、初始窗口及网络重连恢复能力。

- TCP 内存预算按机器内存和真实页大小计算；单 socket 上限使用 2×BDP + 2MiB，并受内存 1/32 与 256MiB 约束。
- tune 默认添加 initcwnd/initrwnd=32，支持 --initcwnd 0..64。只处理单一 IPv4 默认路由，保留当前网关及其它属性，保存原值供回滚。
- systemd 定时恢复服务在重启或同网卡重连后补回受管 FQ 和窗口；回滚先停恢复服务。
- tune --enable-shaping 支持扫描后复测，只有证实吞吐提升或重传显著减少、且无方向明显退化时才持久化整形。测量不可靠时保留基础调优。
- 无遥测，固定版本与 SHA-256 校验。

3Gbps 代理 VPS：

```bash
sudo vps-tcp-tune tune --bandwidth 3000 --role proxy
```

Linux CI 包含 Bash、ShellCheck、功能测试、真实 qdisc 应用/恢复，以及隔离网络中的初始窗口、网关变化、原窗口恢复测试。

当前仍没有在用户这台 VPS 上完成与 tcpfit 的同条件性能对照，不宣称性能已超过 tcpfit。多出口/策略路由的窗口调整、多份调优存档尚未实现。
