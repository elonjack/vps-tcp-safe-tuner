# VPS TCP 自适应调优器

给 Linux VPS 使用的 TCP 调优脚本。它会先测速，再按机器情况调整 BBR、FQ 和 TCP 缓冲区；效果明显变差时会自动恢复。

> 调优不能修复差线路、晚高峰拥堵或商家限速。建议先在非关键 VPS 上测试。

## 小白直接照着做

### 第一步：安装

SSH 登录 VPS 后，复制下面两行执行：

```bash
curl -fLO https://github.com/elonjack/vps-tcp-safe-tuner/releases/download/v4.1.0/install.sh
bash install.sh
```

安装器会校验下载脚本的 SHA-256，安装完成后通常会自动打开中文菜单。

如果没有自动出现菜单，再执行：

```bash
sudo vps-tcp-tune
```

### 第二步：菜单选什么

```text
1) 自适应测试并调优
2) 按已知带宽/RTT 调优
3) 仅检测
4) 查看状态
5) 回滚
0) 退出
```

大多数代理 VPS 选 `1`。接下来这样回答：

1. “对端域名或 IPv4”直接按回车，让脚本选择公共测速节点。
2. “用途”输入 `proxy`。
3. 询问是否安装 iperf3 时输入 `y`。
4. 询问是否允许公共测速节点时输入 `y`。测速节点会看到 VPS 的公网 IP。
5. 脚本显示修改计划后，确认无误再输入 `y`。

脚本会完成“调优前测速 → 临时应用参数 → 再次测速”。如果吞吐明显下降或重传明显增加，会自动恢复本次修改。

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
| 自动测速并调优代理 VPS | `sudo vps-tcp-tune auto --role proxy --allow-public-peers` |
| 查看状态 | `sudo vps-tcp-tune status` |
| 回滚 | `sudo vps-tcp-tune rollback` |
| 查看帮助 | `vps-tcp-tune --help` |

## 运行前要知道

- 只支持 Linux VPS，需要 root 或 `sudo`。
- 自动模式会产生真实测速流量。单个阶段默认最多估算 20 GiB，超过会停止。
- 默认分别测试 VPS 出站和入站，并按实际传输量计算“每 GiB 重传次数”。
- 三轮吞吐波动超过 40% 时会判定公共节点不稳定，在修改系统之前停止。
- 流量有限时可在高级命令末尾加 `--forward-only`，只测 VPS 出站；判断会少一个方向的证据。
- `--allow-public-peers` 表示允许连接内置第三方 iperf3 节点；对端会看到 VPS 的公网 IP。
- 脚本不会修改防火墙、SSH、路由、swap，也不会下载新内核。
- 默认不会替换当前活动 qdisc；只有明确执行整形命令才会修改。
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
- 调优后使用同一对端复测；明显退化或无法完成验证时默认恢复。
- 基础调优保持当前 qdisc 不变，保证调优前后使用同一队列进行 A/B 对比。
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
