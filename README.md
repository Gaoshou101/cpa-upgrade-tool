# cpa-upgrade-tool

CLIProxyAPI (CPA) 与 CPA Manager Plus (CPAMP) 远端 VPS 原生二进制一键升级维护工具。

## 功能特性
- 自动识别架构：支持 `x86_64` (amd64) 与 `aarch64` (arm64)。
- 智能网络加速：自动探测 GitHub 连通性，国内网络自动切换加速镜像。
- 全自动冷备份：升级前自动对旧二进制、配置文件、数据库及 `data.key` 密钥进行快照备份。
- 服务无缝托管：完美支持 `systemctl --user` 用户级 systemd 服务及系统级服务，安全平滑重启。
- 异常自检与回滚：启动失败或健康检查未通过时秒级恢复上一版本。

## 快速使用 (VPS 一键运行)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Gaoshou101/cpa-upgrade-tool/main/upgrade.sh)
```
