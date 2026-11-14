# VPS TCP 自适应调优器

给 Linux VPS 使用的 TCP 调优脚本。可以直接按套餐带宽和业务 RTT 应用 BBR、活动 FQ、自适应 TCP 缓冲区及标准丢包恢复能力，不再把 iperf3 稳定性当成调优前置门槛；深度模式仍可实测择优并在退化时自动恢复。

> 调优不能修复差线路、晚高峰拥堵或商家限速。建议先在非关键 VPS 上测试。

## 小白直接照着做

### 第一步：安装

SSH 登录 VPS 后，复制下面两行执行：

```bash
curl -fLO https://github.com/elonjack/vps-tcp-safe-tuner/releases/download/v6.4.0/install.sh
bash install.sh
```

安装器会校验下载脚本的 SHA-256，安装完成后通常会自动打开中文菜单。

如果没有自动出现菜单，再执行：

```bash
sudo vps-tcp-tune
```

### 第二步：菜单选什么

```text
1) 一键调优（推荐；可直接按套餐带宽调优）
2) 深度自适应实验（缓冲区 + FQ 双向 A/B，流量较大）
3) 按已知带宽/RTT 调优
4) 仅检测
5) 查看状态
6) 回滚
0) 退出
```

大多数代理 VPS 选 `1`。接下来这样回答：

1. “套餐带宽”填 VPS 商家标注的 Mbit/s，例如 `1000`。这是推荐方式。
2. “用途”输入 `proxy`。
3. 基础调优会自动按 `150ms` 跨境目标 RTT 推导，不用再回答 RTT 问题。
4. 脚本显示修改计划后，确认无误输入 `y`。

这条路径不需要 iperf3，会直接完成“精确快照 → BBR + 活动 FQ → 自适应缓冲区 → SACK/DSACK/timestamps 丢包恢复基线 → 持久化”。不满意可用菜单 `6` 精确回滚。

如果不知道套餐带宽，第一问可直接回车，脚本才会进入 iperf3 自动测速模式。

想进一步追求性能、且套餐流量充足时选 `2`。它会额外比较 1×/2×/3× BDP 缓冲区，并临时测试活动 FQ 队列。稳定线路要求双向综合吞吐至少提高 5%；如果基线需要剔除离群轮，脚本会将候选测试自动提高到 5 轮，并要求至少提高 20%。

第一次建议先选 `1`。确认标准模式稳定后，再在业务低峰使用 `2`。

### 第三步：以后怎么打开

```bash
sudo vps-tcp-tune
```

### 不满意怎么恢复

先查看当前状态：

```bash
sudo vps-tcp-tune status
```

恢复第一次调优前的参数：

```bash
sudo vps-tcp-tune rollback
```

回滚只有在所有参数恢复成功后才会删除快照；如果部分恢复失败，快照会保留并提示检查。

## 不想测速，只想按已知带宽调优

下面以 `1000 Mbit/s`、典型 RTT `150 ms`、代理用途为例：

```bash
sudo vps-tcp-tune apply --bandwidth 1000 --rtt 150 --role proxy
```

把 `1000` 换成 VPS 套餐带宽。常见用途：

| 用途 | 参数 |
| --- | --- |
| 代理、转发、流媒体 | `--role proxy` |
| 普通 VPS | `--role general` |
| 建站、服务端 | `--role server` |

只查看计划、不修改系统：

```bash
sudo vps-tcp-tune apply --bandwidth 1000 --rtt 150 --role proxy --dry-run
```

## 常用命令

3Gbps 代理 VPS 可直接执行：

```bash
sudo vps-tcp-tune tune --bandwidth 3000 --role proxy
```

`tune` 同时设置 `initcwnd/initrwnd=32`，原值会保存。用 `--initcwnd 0` 可跳过窗口调整。systemd 恢复服务每 30 秒检查一次，在同一网卡重连、DHCP 更新或重启后补回受管 FQ 和窗口；回滚时先停服务，再恢复原窗口值，沿用当前网关。仅支持单一 IPv4 默认路由，不覆盖策略路由和多路径路由。

TCP 内存预算按真实页大小推导为总内存的 1/16、1/8、1/4；单 socket 上限采用 2×BDP + 2MiB，并受内存 1/32 与 256MiB 约束。代理和通用角色以 1MiB 作为 TCP 收发缓冲起点，避免 200ms 级路径从很小的发送窗口慢慢爬升；总量仍受 `tcp_mem` 约束。Linux 6.6 起废弃的 `tcp_adv_win_scale` 不作为有效调优项写入。

自动测速模式不再把公共 iperf3 对端当作端口硬上限：取出站/入站较大实测值后，增加 50% 容量余量并向上取常见端口档位，只用来推导 TCP 自动调谐的最大窗口。例如实测约 1664M 会按 3000M 档推导，在 150ms RTT、内存充足时得到约 109.3MiB 上限。该上限不是每连接预分配，也不会抬高测速成绩或整形速率；显式 `--bandwidth` 仍严格使用用户给定值。

脚本会显式恢复 Linux 默认启用的 `tcp_sack=1`、`tcp_dsack=1`、`tcp_timestamps=1`，并恢复 `tcp_no_metrics_save=0`。v6.4.0 进一步恢复 `tcp_early_retrans=3`、`tcp_recovery=1` 与 `tcp_reordering=3`，让 TLP/RACK 继续负责尾丢包和乱序恢复；同时启用 `tcp_fastopen=3` 的客户端/服务端基础能力。它们主要修复其它调优脚本留下的有害值，不保证改变长连接峰值。所有值都会进入快照、冲突检测、读回验证和回滚。

如果还要自动扫描并验证整形，指定可信近端 iperf3 对端：

```bash
sudo vps-tcp-tune tune --bandwidth 3000 --role proxy \
  --peer 你的近端测速服务器IP --enable-shaping --duration 5 --rounds 3
```

只有测量可靠且重传较高时才进入扫描；候选整形经复测达到“吞吐提高至少 5%”，或“吞吐保持 95% 且重传至少减半”，并且任一方向无明显退化，才自动持久化。测量不足时保留已完成的基础调优，不会宣称测速优化成功。扫描会产生较多实际流量，超过默认护栏仍需 `--allow-high-traffic`。

| 想做什么 | 命令 |
| --- | --- |
| 打开中文菜单 | `sudo vps-tcp-tune` |
| 只检查环境 | `sudo vps-tcp-tune audit` |
| 按 1000M 带宽一键调优代理 VPS | `sudo vps-tcp-tune tune --bandwidth 1000 --role proxy` |
| 自动测速并调优代理 VPS | `sudo vps-tcp-tune auto --role proxy --allow-public-peers` |
| 深度实验并自动择优 | `sudo vps-tcp-tune deep --role proxy --allow-public-peers` |
| 查看状态 | `sudo vps-tcp-tune status` |
| 回滚 | `sudo vps-tcp-tune rollback` |
| 查看帮助 | `vps-tcp-tune --help` |

## 运行前要知道

- 只支持 Linux VPS，需要 root 或 `sudo`。
- 自动模式会产生真实测速流量。每个测量阶段默认上限 20 GiB；除了事前估算，还会按实际传输字节在运行中停止后续测试。
- 默认分别测试 VPS 出站和入站，并按实际传输量计算“每 GiB 重传次数”。
- 三轮吞吐波动超过 40% 时会判定样本不可靠；一键按套餐带宽调优不受此限制。
- 使用至少五轮测试时，可使用占多数且仍满足波动门槛的稳定样本簇；被剔除轮次的流量仍计入上限。没有多数稳定簇时仍会停止。
- 流量有限时可在高级命令末尾加 `--forward-only`，只测 VPS 出站；判断会少一个方向的证据。
- `--allow-public-peers` 表示允许连接内置第三方 iperf3 节点；对端会看到 VPS 的公网 IP。
- 脚本不会修改防火墙、SSH、swap，也不会下载新内核。`tune` 会调整单一 IPv4 默认路由的初始窗口，保留当前网关及其它路由属性；多出口、IPv6-only 和特殊路由会跳过该项。
- 一键/标准模式会在保存精确快照后应用活动 FQ；遇到无法精确恢复的特殊 qdisc 会拒绝修改。深度模式会先 A/B，未达择优门槛就恢复原队列。
- 应用前会扫描其它持久化 sysctl 文件：较早加载的重复项会提示，可能在本工具之后覆盖运行值的文件会阻断。只有审阅后才能用 `--allow-sysctl-conflicts` 显式放行阻断项。
- 写入后会逐项读回内核运行值；持久化文件还会重新加载验证。`status` 会报告配置与运行值漂移，不把“文件存在”误当成“调优生效”。
- 会管理 SACK、DSACK、TCP timestamps、路由指标缓存与有限的 softnet 预算；若旧配置文件也设置这些键，会按同一冲突规则提示或阻断。
- OpenVZ/LXC 可能禁止 BBR、sysctl 或 qdisc，遇到限制时脚本会停止，不会强行修改。

## 使用自己的测速服务器

公共 iperf3 节点可能繁忙。想要更稳定的测试，可以在另一台 VPS 上运行：

```bash
iperf3 -s
```

然后在需要调优的 VPS 上执行：

```bash
sudo vps-tcp-tune auto --peer 你的服务器IP --role proxy
```

指定自己的对端时，不需要 `--allow-public-peers`。

## 高流量和高级测试

普通用户不需要这一节。

默认流量上限为每个阶段 20 GiB。可以调低：

```bash
sudo vps-tcp-tune auto --role proxy --allow-public-peers --max-test-gib 5
```

如果确认套餐流量充足，才显式允许超过上限：

```bash
sudo vps-tcp-tune auto --role proxy --allow-public-peers --allow-high-traffic
```

搜索 1×、2×、3× BDP 缓冲区会额外测速：

```bash
sudo vps-tcp-tune auto --role proxy --allow-public-peers --search-buffers
```

直接运行完整深度实验（等价于开启缓冲区搜索和活动 FQ 实验）：

```bash
sudo vps-tcp-tune deep --role proxy --allow-public-peers
```

`--yes` 不能代替公共节点授权或高流量授权。

## 限速器与整形

只有确认出口限速器导致重传或吞吐不稳时，才建议整形。扫描只给出建议，不会自动长期应用：

```bash
sudo vps-tcp-tune auto --role proxy --allow-public-peers --enable-shaping
```

根据扫描建议手动应用，例如建议值为 950 Mbit/s：

```bash
sudo vps-tcp-tune shape --shape-rate 950 --enable-shaping
```

移除本工具整形并恢复原 qdisc：

```bash
sudo vps-tcp-tune unshape
```

整形会短暂替换活动根 qdisc，应在业务低峰操作。无法精确恢复的自定义 qdisc 会被拒绝。

## 安全设计

- 主脚本没有遥测、运行计数、广告请求或自动更新。
- 主脚本不会下载并执行远程代码。
- 公共测速节点和高流量测试分别需要明确授权。
- 首次修改前保存 sysctl 精确快照；本次实验另有事务快照。
- 事务同时保护受管 sysctl 配置文件；加载或读回失败时恢复旧文件，不留下重启才生效的半成品。
- 持久化文件使用原子写入和所有权标记，不覆盖同名第三方文件。
- 写入 systemd 脚本前严格校验网卡名，整形服务限制文件系统权限和 capability。
- 自动/深度模式会使用同一对端复测；明显退化或无法完成验证时默认恢复。
- 一键调优将 BBR 与活动 FQ 成对应用，并为活动队列保存独立回滚快照；深度模式则分别测量原队列和 FQ。
- 安装器固定 Release 版本并使用内置 SHA-256 校验主脚本。

对参考项目 tcpfit v0.5.9 的静态安全审阅见 [SECURITY-REVIEW-tcpfit.md](SECURITY-REVIEW-tcpfit.md)。

## 离线安装

已经下载完整 Release 或仓库时：

```bash
sha256sum -c SHA256SUMS
sudo bash install.sh --local ./vps-tcp-tune.sh
```

## 支持范围

需要 Linux、`sysctl` 和 `iproute2`。整形还需要 `tc` 与 systemd。Debian、Ubuntu、Rocky Linux、AlmaLinux、CentOS、Fedora 和 Alpine 一般可用。

## 开发测试

```bash
bash -n vps-tcp-tune.sh
bash tests/test-shell.sh
shellcheck vps-tcp-tune.sh install.sh tests/test-shell.sh
powershell -ExecutionPolicy Bypass -File tests/test-static.ps1
```

## 许可证

[MIT License](LICENSE)
