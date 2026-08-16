# 贡献指南

欢迎提出 issue 和 pull request。涉及内核参数时，请同时说明适用内核、测试环境、吞吐/重传测量方法以及回滚影响。

提交前请运行：

```bash
bash -n vps-tcp-tune.sh
shellcheck vps-tcp-tune.sh
```

不要加入未经明确确认的远程执行、自动安装依赖、修改防火墙/路由，或无法精确回滚的系统改动。
