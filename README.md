# VPS TCP 自适应调优器

给 Linux VPS 使用的 TCP 调优脚本。可以直接按套餐带宽和业务 RTT 应用 BBR、活动 FQ 和自适应 TCP 缓冲区，不再把 iperf3 稳定性当成调优前置门槛；深度模式仍可实测择优并在退化时自动恢复。

> 调优不能修复差线路、晚高峰拥堵或商家限速。建议先在非关键 VPS 上测试。

## 小白直接照着做

### 第一步：安装

SSH 登录 VPS 后，复制下面两行执行：

```bash
curl -fLO https://github.com/elonjack/vps-tcp-safe-tuner/releases/download/v6.0.0/install.sh
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
3. “业务目标 RTT”填真实用户到 VPS 的典型延迟；不确定就直接回车，默认 `150`。
4. 脚本显示修改计划后，确认无误输入 `y`。

这条路径不需要 iperf3，会直接完成“精确快照 → BBR + 活动 FQ → 自适应缓冲区 → 持久化”。不满意可用菜单 `6` 精确回滚。

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

| 想做什么 | 命令 |
| --- | --- |
| 打开中文菜单 | `sudo vps-tcp-tune` |
| 只检查环境 | `sudo vps-tcp-tune audit` |
| 按 1000M 带宽一键调优代理 VPS | `sudo vps-tcp-tune tune --bandwidth 1000 --rtt 150 --role proxy` |
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
- 脚本不会修改防火墙、SSH、路由、swap，也不会下载新内核。
- 一键/标准模式会在保存精确快照后应用活动 FQ；遇到无法精确恢复的特殊 qdisc 会拒绝修改。深度模式会先 A/B，未达择优门槛就恢复原队列。
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
