# v6.4.0：自动窗口容量与现代丢包恢复

本版针对高延迟跨境单线程继续增强，但不承诺通过堆参数绕过线路拥堵、运营商限速或路由差异。

主要变化：

- 自动测速得到的吞吐仍作为真实成绩；TCP 最大窗口另按 150% 容量余量向上取常见端口档位。实测约 1664M 时会按 3000M 档推导，在 150ms RTT、内存充足时约为 109.3MiB。
- 窗口上限仍受内存 1/32、256MiB 绝对上限及 TCP 总内存预算保护；它是自动调谐天花板，不是每连接预分配。
- 显式恢复 TLP、RACK 和正常初始重排序阈值：`tcp_early_retrans=3`、`tcp_recovery=1`、`tcp_reordering=3`。
- 启用 `tcp_fastopen=3` 基础能力；只有应用实际使用 TFO 时才会缩短握手。
- 新增的所有 sysctl 均参与冲突检测、快照、事务恢复、读回验证和完整回滚。

安装：

```bash
curl -fLO https://github.com/elonjack/vps-tcp-safe-tuner/releases/download/v6.4.0/install.sh
bash install.sh
```

推荐代理 VPS 直接输入套餐带宽：

```bash
sudo vps-tcp-tune tune --bandwidth 3000 --role proxy
```

不知道套餐带宽时再使用自动测速：

```bash
sudo vps-tcp-tune auto --role proxy --allow-public-peers
```
