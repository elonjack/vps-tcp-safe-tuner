# VPS TCP 安全调优器

一个面向 Linux VPS 的保守 TCP 调优脚本。它不承诺“万能提速”，而是把风险较低、可解释的 TCP 设置做成可预览、可回滚的流程。

> 适用于拥有 root 权限的 Linux VPS。支持 Debian、Ubuntu、Rocky Linux、AlmaLinux、CentOS Stream、Alpine 等使用 Linux sysctl 的系统；不支持 Windows、macOS，受限 OpenVZ/LXC 容器可能拒绝部分内核参数。

## 为什么要有这个脚本

网络质量主要由线路、拥塞、对端、套餐限速和应用协议决定。TCP 调优只能改善本机内核的发送/接收行为，不能把差路由变成优质线路，也不能让低带宽套餐突破服务商限速。

默认的“安全档”只在内核原生支持时设置：

- `net.ipv4.tcp_congestion_control=bbr`
- `net.core.default_qdisc=fq`

“高吞吐档”需要明确提供标称带宽与典型 RTT。脚本按 `2 × 带宽 × RTT` 计算单连接缓冲区上限，并限制在 4–64 MiB 与内存的 1/16 以内；它还启用 TCP MTU 探测与空闲后不重启慢启动。脚本不会用固定的“神参数”。

## 安全边界

本项目刻意不做下面的事：

- 不使用 `curl | bash`，不下载或执行远程代码
- 不自动安装软件包、不运行 `apt update`
- 不创建 swap，不改防火墙、路由、DNS、SSH 或 `tc` 限速
- 不替换活动网卡的 qdisc，避免中断现有连接
- 不覆盖未知的旧配置；首次修改前保存精确快照，失败时尝试立即恢复

持久化配置仅写入 `/etc/sysctl.d/99-vps-tcp-safe-tuner.conf`；状态与快照仅保存于 `/var/lib/vps-tcp-safe-tuner/`。执行 `rollback` 会按首次快照恢复并只删除本项目创建的文件。

## 安装与使用

从 GitHub Release 下载脚本后，先校验 SHA-256，再在 VPS 上执行。请不要直接把网络内容管道给 shell。

```bash
chmod 755 vps-tcp-tune.sh
sudo ./vps-tcp-tune.sh preview
sudo ./vps-tcp-tune.sh apply
sudo ./vps-tcp-tune.sh status
```

高吞吐档示例：一台 1 Gbit/s VPS，主要访问目标的典型 RTT 为 150 ms。

```bash
sudo ./vps-tcp-tune.sh preview --profile throughput --bandwidth 1000 --rtt 150
sudo ./vps-tcp-tune.sh apply --profile throughput --bandwidth 1000 --rtt 150
```

非交互自动化必须显式确认，并建议先执行预览：

```bash
sudo ./vps-tcp-tune.sh apply --profile safe --yes
```

恢复：

```bash
sudo ./vps-tcp-tune.sh rollback
```

所有用户可见提示在终端中为黄色；重定向到日志时会自动取消 ANSI 颜色，保证日志可读。

## 选择哪一档

| 情况 | 建议 |
| --- | --- |
| 不确定套餐带宽、内存很小、业务正在运行 | `safe` |
| 已经确认带宽和典型 RTT，内存至少 512 MiB，追求大文件/代理吞吐 | `throughput` |
| 主要问题是中国方向高延迟、晚高峰抖动、服务商丢包或带宽封顶 | 优先换线路/机房或测试对端；调参通常不能根治 |

## 关于 Kylin010/tcpfit

`tcpfit` 的思路包括 BBR/FQ、缓冲区与连接参数调整，并以 iperf3 扫描服务商出口限速器的拐点，再使用 `tc` 限速和平滑发送来减少 policer 丢包。它有快照和回滚设计，审阅中未发现明显后门或窃密行为；但它修改范围较大，且依赖公共测速节点、可安装依赖、可创建 swap、可修改 qdisc/路由初始化窗口。因此不适合作为“所有 VPS 都直接全自动执行”的默认方案。

对延迟很高但重传很低的跨境线路，尤其是中国回程测试，TCP 参数通常无法显著降低 RTT；测速结果应以同一对端、相同时间段的应用层吞吐和重传为准。

## 验证与故障处理

先运行：

```bash
sudo ./vps-tcp-tune.sh status
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
```

`default_qdisc=fq` 不会强制替换正在运行的根队列。为避免影响连接，请在业务低峰重启 VPS 后再查看 `status` 中的“活动根队列”。如果应用出现异常或容器拒绝写入 sysctl，立即执行 `rollback`。

## 开发

```bash
bash -n vps-tcp-tune.sh
shellcheck vps-tcp-tune.sh
powershell -ExecutionPolicy Bypass -File tests/test-static.ps1
```

CI 会运行 Bash 语法检查、ShellCheck 和静态安全断言。

## 许可证

本项目使用 [MIT License](LICENSE)。
