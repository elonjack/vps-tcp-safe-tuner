# v6.3.0

这一版针对一种很隐蔽的退化：近端、零丢包方向能跑满几 Gbps，但 200–300ms 且存在少量丢包的国内单线程只有几 Mbps。

- 显式恢复 Linux 默认的 SACK、DSACK 和 TCP timestamps，避免机器以前运行过其它调优脚本后仍带着关闭丢包恢复的旧值。
- 恢复 TCP 路由指标缓存；代理和通用角色使用 1MiB TCP 收发缓冲起点，高 BDP 单流不再从过小窗口慢慢爬升。
- softnet backlog 使用 16384（5Gbps 及以上 32768），单轮处理预算使用 600；没有加入 `tcp_reordering=300`、固定 `tcp_adv_win_scale` 等激进或已废弃参数。
- 所有新增参数都使用既有的精确快照、冲突检测、写后读回、事务恢复和回滚机制。

典型代理 VPS：

```bash
sudo vps-tcp-tune tune --bandwidth 你的套餐带宽 --role proxy
```

应用前建议先运行 `sudo vps-tcp-tune audit`。如果报告其它 sysctl 文件冲突，应先审阅旧文件；不要直接放行来源不明的配置。
