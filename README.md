# VPS TCP 自适应调优器

面向 Linux VPS 的 TCP 调优与验证工具。它可通过可信 iperf3 对端测出实际吞吐、重传和 RTT，按 BDP、内存与用途推导缓冲区和队列参数，并提供可选 HTB + FQ 整形、验证和回滚。

> 没有任何 TCP 脚本可以让所有 VPS 都变快。线路、套餐限速、对端性能和晚高峰拥塞才是决定因素。本项目坚持“先测量、再调整、再验证；无收益可回滚”。

## 能力

| 能力 | 说明 |
| --- | --- |
| 机器画像 | 内核、BBR、内存、虚拟化、默认网卡与活动 qdisc 检测 |
| 真实测量 | 指定 iperf3 对端，多流吞吐、发送端重传、平均 RTT |
| 自适应 BDP | 使用实测带宽和 RTT，按用途与内存限制推导 TCP 缓冲区 |
| TCP 调优 | BBR、FQ 默认队列、收发缓冲区、MTU 探测、慢启动、backlog 与连接队列 |
| 限速器处理 | 可选、明确确认的 HTB + FQ 整形；先扫描候选，绝不默认改活动 qdisc |
| 持久化与回滚 | 专属 sysctl/systemd 文件；首次变更前保存精确 sysctl 快照 |

## 安全设计

- 不使用 `curl | bash`，不下载或执行远程代码。
- iperf3 缺失时才会询问是否安装系统包；绝不运行 `apt update`。
- 默认不触碰正在运行的根 qdisc；整形必须额外使用 `--enable-shaping` 并确认。
- 只接受域名或 IPv4 形式的对端，所有参数有范围校验。
- 受限 OpenVZ/LXC、特殊 `mq` 根队列、无法安全恢复的 qdisc 会被拒绝。
- 终端提示为黄色；重定向日志时自动移除 ANSI 颜色。

## 支持范围

需要 Linux、root、`sysctl`、`iproute2`。整形还需要 `tc` 与 systemd。Debian/Ubuntu、Rocky/Alma/CentOS、Fedora、Alpine 一般可用；缺少 BBR 或被容器限制 sysctl 时，工具会停止并说明原因。

## 快速开始

```bash
chmod 755 vps-tcp-tune.sh
sudo ./vps-tcp-tune.sh audit
```

推荐准备一台自有或可信的 iperf3 服务端：

```bash
iperf3 -s
```

在 VPS 客户端进行自适应调优：

```bash
sudo ./vps-tcp-tune.sh auto --peer YOUR_IPERF3_HOST --role proxy
```

该流程会先测量、显示推导参数、确认后应用，并立即再次验证。测速会消耗流量，默认每次为 4 流、12 秒。

如果已知出口带宽与典型 RTT：

```bash
sudo ./vps-tcp-tune.sh apply --bandwidth 1000 --rtt 150 --role proxy
```

## 限速器与整形

只有出口 policer 导致重传或吞吐不稳时，整形才可能改善代理/大流吞吐。先使用同一可信对端完成 `auto`，再比较候选值：

```bash
sudo ./vps-tcp-tune.sh shape --shape-rate 950 --enable-shaping
sudo ./vps-tcp-tune.sh verify --peer YOUR_IPERF3_HOST
```

整形会短暂替换活动根 qdisc，必须在业务低峰执行。脚本只允许恢复把握足够的根队列类型；遇到多队列或自定义 qdisc 会拒绝操作。

## 其他命令

```bash
sudo ./vps-tcp-tune.sh measure --peer YOUR_IPERF3_HOST
sudo ./vps-tcp-tune.sh status
sudo ./vps-tcp-tune.sh apply --bandwidth 1000 --rtt 150 --dry-run
sudo ./vps-tcp-tune.sh rollback
```

## 与 tcpfit 的定位

`tcpfit` 的核心优点是 BDP、iperf3 和 policer 扫描。本项目同样采用“测量—推导—应用—验证”闭环，但使用用户指定的可信对端，并将会影响现网的 qdisc 整形置于显式能力之后。性能优劣必须以同一时间、同一对端、调优前后的吞吐和重传实测判断，不能靠参数数量判断。

## 开发

```bash
bash -n vps-tcp-tune.sh
shellcheck vps-tcp-tune.sh
powershell -ExecutionPolicy Bypass -File tests/test-static.ps1
```

GitHub Actions 会执行 Bash 语法检查、ShellCheck 与静态安全断言。

## 许可证

[MIT License](LICENSE)
