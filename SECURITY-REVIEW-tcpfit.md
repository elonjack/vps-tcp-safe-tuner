# tcpfit 安全审计摘要

审计对象：`Kylin010/tcpfit`，提交 `38fbf5af30daf87735f2ffbc5e0905033ee2b86e`（v0.5.9，2026-10-01）。

## 结论

未发现挖矿程序、反向 shell、SSH 公钥注入、凭据窃取、cron 后门或把系统信息上传到第三方的明确恶意逻辑。它的 TCP 推导、快照、qdisc 与 initcwnd 持久化实现包含不少认真处理过的边界情况，不能简单归类为“恶意脚本”。

但它不满足本项目采用的“默认零遥测、外联必须显式授权、远程代码必须固定且校验、SSH 主机身份必须验证”基线。下面的行为在 root 脚本中尤其值得注意。

## 主要发现

### 中等：默认运行统计会把来源 IP 暴露给作者服务器

`tcpfit.sh` 的 `telemetry_ping` 会在启动菜单时后台请求 `https://tcpfit.spacevps.cc/ping?v=<版本>`。请求参数看起来只有版本号，但任何 HTTP 服务及其上游 CDN、DNS 和网络日志都可以观察来源 IP、时间和 TLS/HTTP 元数据。因此“没有机器标识”不等于“匿名”。用户可以通过环境变量或状态文件关闭，但默认是开启的。

本项目不实现运行计数或遥测；主脚本中也用静态断言禁止作者控制的统计端点。

### 中等：root 运行时会无确认下载并安装另一份脚本

`self_install` 会从版本 tag 的 raw GitHub URL 下载 `tcpfit.sh` 到 `/usr/local/bin/tcpfit`。它验证 shebang 和版本字符串，但没有在这条路径上验证内置 SHA-256 或签名。固定 tag 比直接追踪 `main` 好，但仓库、tag 或账号被篡改时，版本字符串检查不能证明内容可信。

本项目把远程下载限制在独立安装器中，固定 Release 版本并使用安装器内置哈希；主调优脚本永不自更新或下载代码，并支持 `install.sh --local` 离线安装。

### 中等：多机编排关闭 SSH 主机密钥检查

`orchestrator/fleet.py` 对 `ssh` 和 `scp` 使用 `StrictHostKeyChecking=no`。这使首次连接及已变化的主机身份无法得到正常保护，可能把 root 脚本和密码发送给中间人。示例清单还支持明文密码并通过 `sshpass -p` 传入，密码可能短暂出现在本机进程参数中。

本项目当前不提供多机密码编排。若未来加入，应默认使用已有 `known_hosts`、`StrictHostKeyChecking=yes/accept-new` 与 SSH agent，不把密码放入命令行。

### 低到中等：修改范围较大，部分参数不是纯 TCP 局部优化

除 BBR、FQ 和 TCP 缓冲区外，tcpfit 还设置全局 socket 默认缓冲区、`vm.min_free_kbytes`、`fs.file-max`、较短的 `tcp_fin_timeout`、扩大的本地端口范围、TCP Fast Open 以及路由 `initcwnd/initrwnd`。这些设置未必恶意，但会影响 UDP、内存保留、文件句柄或所有 TCP 业务，风险面明显大于“只调 TCP”。固定的 `vm.min_free_kbytes=32768` 对极小内存 VPS 也未必合适。

本项目刻意不修改全局 `rmem_default/wmem_default`、VM、文件句柄、防火墙、路由、swap 和 SSH，只管理与目标直接相关且可快照恢复的少量 sysctl；活动 qdisc 仅在显式整形时修改。

### 信息：项目带有推广内容

完成页面打印 Telegram 频道、VPS 站点和合作邮箱。这不构成系统后门，但属于与调优功能无关的推广内容，使用者应知情。

## 建议的使用方式

如果仍要使用 tcpfit，至少应先下载固定提交或 release 到本地，核对完整源码和哈希，关闭 telemetry，避免 `bash <(curl ...)`，不要使用关闭主机密钥校验的多机编排，并在测试机上验证 rollback 后再用于生产 VPS。

本审计是针对上述提交的静态审阅，不代表未来提交；域名服务端行为也无法仅凭客户端仓库源码完全证明。
