# cpa-upgrade-tool

CLIProxyAPI (CPA) 与 CPA Manager Plus (CPAMP) 远端 VPS 原生二进制一键升级维护工具。

## 功能特性
- **架构智能匹配**：自动识别并适配 `x86_64` (amd64) 与 `aarch64` (arm64)。
- **网络自适应加速**：自动探测 GitHub 直连速度，连接超时自动切换加速镜像。
- **灵活备份策略**：
  - **备份后升级**：自动对二进制、配置文件、SQLite 数据库及 `data.key` 进行快照冷备，启动异常自动回滚。
  - **无备份直接升级**：专门针对**小硬盘 / 磁盘空间告警**的 VPS 优化，升级时不额外生成历史备份，极致省空间。
- **平滑进程托管**：
  - 支持 `systemctl --user`、系统级 `systemctl`；
  - 无 systemd 单元时无缝接管官方 `run.sh` 与 `cpa-manager-plus.pid`，无需手动改写服务。
- **智能路径探测**：
  - 优先从运行中进程（`/proc/<pid>/exe`）与 systemd 配置自动提取；
  - 支持官方安装器路径（`~/cliproxyapi/` 与 `~/cpa-manager-plus/`）；
  - 支持输入目录自动嗅探内部二进制。

## 快速使用 (VPS 一键运行)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Gaoshou101/cpa-upgrade-tool/main/upgrade.sh)
```
*(如遇 GitHub 网络不畅，可加镜像前缀：`bash <(curl -fsSL https://gh.jasonzeng.dev/https://raw.githubusercontent.com/Gaoshou101/cpa-upgrade-tool/main/upgrade.sh)`)*
