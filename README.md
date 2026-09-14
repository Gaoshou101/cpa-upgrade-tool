# cpa-upgrade-tool

CLIProxyAPI (CPA) 与 CPA Manager Plus (CPAMP) 远端 VPS 原生二进制一键安装、升级与运维综合管理工具箱。

## ✨ 功能特性

### 1. 全新一键安装部署
- **CPA 快速原生安装**：
  - 自动抓取 GitHub 最新 Release 二进制包；
  - 自动创建并注册 `systemctl --user` 守护服务，配置 `default.target` 实现开机常驻；
  - 自动补齐初始 `config.yaml` 配置文件与端口设置（默认 `:8317`）。
- **CPAMP 面板标准化安装**：
  - 自动对齐官方一键安装器（`install-cpamp.sh`）进行原生标准部署；
  - 自动配置 `run.sh` 启动脚本、PID 管理与数据目录隔离。

### 2. 智能版本升级维护
- **架构智能匹配**：自动识别并适配 `x86_64` (amd64) 与 `aarch64` (arm64)。
- **网络自适应加速**：自动探测 GitHub 直连速度，连接超时自动切换加速镜像。
- **灵活备份策略**：
  - **备份后升级**：自动对二进制、配置文件、SQLite 数据库及 `data.key` 进行快照冷备，启动异常自动回滚。
  - **无备份直接升级**：专门针对**小硬盘 / 磁盘空间告警**的 VPS 优化，升级时不额外生成历史备份，极致节省空间。
- **5 级高容错路径探测**：
  - 优先从运行中进程（`/proc/<pid>/exe`）精准嗅探；
  - 自动从 systemd 配置解析 `ExecStart`；
  - 自动适配官方默认安装目录（`~/cliproxyapi/` 与 `~/cpa-manager-plus/`）；
  - 支持手动输入目录自动嗅探其内部二进制。
- **双模进程平滑热启**：
  - 优先采用 systemd 优雅停启；
  - 无 systemd 单元时无缝接管官方 `run.sh` 与 `cpa-manager-plus.pid`，无需手动改写服务配置。

---

## 🚀 快速使用 (VPS 一键运行)

### 常用一键脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Gaoshou101/cpa-upgrade-tool/main/upgrade.sh)
```

*(国内 VPS 网络不畅时可使用加速镜像)*：
```bash
bash <(curl -fsSL https://gh.jasonzeng.dev/https://raw.githubusercontent.com/Gaoshou101/cpa-upgrade-tool/main/upgrade.sh)
```

---

## 📋 菜单交互演示

```text
==============================================================
      CLIProxyAPI & CPA Manager Plus 综合管理工具箱            
==============================================================
1. 智能版本升级 (支持 CPA/CPAMP、全自动探测、备份/小硬盘无备份模式)
2. 全新一键安装 (支持 CPA 原生/守护、CPAMP 标准化安装)
3. 退出
请选择操作 [1-3] (默认 1): 

[升级子菜单]
1. 升级全部 (CPA + CPAMP)
2. 仅升级 CLIProxyAPI (CPA)
3. 仅升级 CPA Manager Plus (CPAMP)
4. 返回上一层
  └─ 二级选项：1. 备份后升级 (安全回滚) / 2. 无备份直接升级 (小硬盘专属)

[安装子菜单]
1. 安装全部 (CPA + CPAMP 标准套件)
2. 仅安装 CLIProxyAPI (CPA 网关)
3. 仅安装 CPA Manager Plus (CPAMP 面板)
4. 返回上一层
```
