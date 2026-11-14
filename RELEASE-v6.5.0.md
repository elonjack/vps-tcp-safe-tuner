# v6.5.0：真正的五阶段一键调优

本版把原先的“快速基础配置”与“完整一键自适应”正式分开。

菜单1现在依次执行：

1. 基础调优：快照、BBR、活动FQ、自适应缓冲区、丢包恢复、initcwnd。
2. 路径质量：以套餐带宽的40%临时整形，测量低于policer拐点时的线路底噪。
3. 拐点扫描：从全速基线的55%到145%粗扫，找到干净/丢包边界后再二分精扫。
4. 候选整形：在拐点前保留3%余量，临时应用HTB+FQ。
5. 最终复测：同一对端验证吞吐和重传，达标才持久化；否则恢复纯FQ。

原先几秒完成的确定性配置保留为菜单2“快速基础调优”。应用结果会明确显示真正改变了多少项、多少项本来就一致。

安装：

```bash
curl -fLO https://github.com/elonjack/vps-tcp-safe-tuner/releases/download/v6.5.0/install.sh
bash install.sh
```

非菜单方式：

```bash
sudo vps-tcp-tune wizard --bandwidth 3000 --role proxy --allow-public-peers
```

五阶段流程会产生大量真实测速流量；超过默认20GiB护栏时必须明确授权。调优无法修复跨运营商拥堵、差路由或对端容量不足。
