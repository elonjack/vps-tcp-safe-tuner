# VPS TCP 自适应调优器

面向 Linux VPS 的 TCP 调优与验证工具。它可通过可信 iperf3 对端测出实际吞吐、重传和 RTT，按 BDP、内存与用途推导缓冲区和队列参数，并提供可选 HTB + FQ 整形、验证和回滚。

> 没有任何 TCP 脚本可以让所有 VPS 都变快。线路、套餐限速、对端性能和晚高峰拥塞才是决定因素。本项目坚持“先测量、再调整、再验证；无收益可回滚”。

## 能力

| 能力 | 说明 |
| --- | --- |
| 机器画像 | 内核、BBR、内存、虚拟化、默认网卡与活动 qdisc 检测 |
| 多轮基准实验 | 同一对端多轮测试，使用中位吞吐减少偶发波动；记录重传、RTT 与估算流量 |
| 自适应 BDP | 使用实测带宽和 RTT，按用途与内存限制推导 TCP 缓冲区 |
| 缓冲区 A/B 搜索 | 可选比较 1×、2×、3× BDP 缓冲区，保留吞吐最高且重传可接受的候选 |
| TCP 调优 | BBR、FQ 默认队列、收发缓冲区、MTU 探测、慢启动、backlog 与连接队列 |
| 限速器处理 | 可选、明确确认的 HTB + FQ 整形；基线噪声感知的 85%–145% 粗扫、三轮复测、二分精扫与安全余量建议 |
| 多队列恢复 | 保存常见单根 qdisc 参数；对常见 `mq` 多队列根同时保存每个可恢复叶子队列并逐个恢复 |
| 性能保护 | 调优前后使用相同对端复测；吞吐明显退化或重传明显增加时默认自动回滚 |
| 持久化与回滚 | 专属 sysctl/systemd 文件；首次变更前保存精确 sysctl 快照与实验报告 |

## 安全设计

- 不使用 `curl | bash`，不下载或执行远程代码。
- iperf3 缺失时才会询问是否安装系统包；绝不运行 `apt update`。
- 默认不触碰正在运行的根 qdisc；整形必须额外使用 `--enable-shaping` 并确认。
- 只接受域名或 IPv4 形式的对端，所有参数有范围校验。
- 受限 OpenVZ/LXC、无法精确重建的自定义 qdisc 会被拒绝；支持的 `fq`、`fq_codel`、`pfifo*` 会保存参数后恢复，常见 `mq` 多队列会额外保存并恢复每个受支持的叶子队列。
- 终端提示为黄色；重定向日志时自动移除 ANSI 颜色。

## 支持范围

需要 Linux、root、`sysctl`、`iproute2`。整形还需要 `tc` 与 systemd。Debian/Ubuntu、Rocky/Alma/CentOS、Fedora、Alpine 一般可用；缺少 BBR 或被容器限制 sysctl 时，工具会停止并说明原因。

## 快速开始

一键安装固定版本。安装器会下载 GitHub Release 资产并在安装前校验 SHA-256：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/elonjack/vps-tcp-safe-tuner/v3.3.1/install.sh)
```

安装后可直接运行：

```bash
sudo vps-tcp-tune audit
sudo vps-tcp-tune
```

也可下载仓库中的脚本后手动执行：

```bash
chmod 755 vps-tcp-tune.sh
sudo ./vps-tcp-tune.sh audit
```

直接一键调优时无需你另买 VPS：省略 `--peer` 后，脚本会从内置公共 iperf3 节点中按 RTT 排序、多个端口短测后选择可用对端。默认只接受 RTT 不超过 120 ms 的节点，可通过 `--peer-max-rtt` 调整。公共节点可能满载或临时不可用；这种情况下可稍后重试，或指定你自己的可信对端以获得更稳定的结果。

最简单的一键调优：

```bash
sudo vps-tcp-tune
```

也可以明确使用自动公共节点：

```bash
sudo vps-tcp-tune auto --role proxy --rounds 3
```

若需最可重复、最贴近业务目标的测量，推荐准备一台自有或可信的 iperf3 服务端：

```bash
iperf3 -s
```

指定对端的自适应调优：

```bash
sudo ./vps-tcp-tune.sh auto --peer YOUR_IPERF3_HOST --role proxy
```

该流程会先记录 3 轮基准、显示推导参数、确认后应用，再以同一对端复测 3 轮。若吞吐下降超过 15%，或原本零重传而复测累计出现超过 10 次重传，默认自动回滚。测速会消耗流量，默认每轮为 4 流、12 秒；可用 `--rounds 1` 到 `--rounds 5` 调整。

如需进一步针对当前线路搜索缓冲区上限，可显式启用 A/B 搜索。该模式会额外进行 3 组、每组 2 轮测试，因此仅建议在流量充足且业务低峰时使用：

```bash
sudo vps-tcp-tune auto --role proxy --search-buffers
```

如果已知出口带宽与典型 RTT：

```bash
sudo ./vps-tcp-tune.sh apply --bandwidth 1000 --rtt 150 --role proxy
```

## 限速器与整形

只有出口 policer 导致重传或吞吐不稳时，整形才可能改善代理/大流吞吐。启用 `--enable-shaping` 后，自动流程会从基线的 85% 到 145% 粗扫；每个候选默认独立测试 3 轮，并按基线重传噪声与至少 90% 的送达率共同判定。发现拐点后改用二分法精扫，在最佳候选下方保留 3% 余量。完成后只给出建议，不会自动持久化整形。

可用 `--policer-rounds 2` 到 `--policer-rounds 5` 调整每个候选的测试轮数；更多轮次更稳，但会消耗更多测试流量。扫描中无论正常结束、报错退出或收到中断，都会先恢复扫描前的根 qdisc；遇到自定义或无法逐叶恢复的多队列配置时，脚本会拒绝扫描。

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

## 开发

```bash
bash -n vps-tcp-tune.sh
shellcheck vps-tcp-tune.sh
powershell -ExecutionPolicy Bypass -File tests/test-static.ps1
```

GitHub Actions 会执行 Bash 语法检查、ShellCheck 与静态安全断言。

## 许可证

[MIT License](LICENSE)
