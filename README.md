# cpa-upgrade-tool

CLIProxyAPI (CPA) 与 CPA Manager Plus (CPAMP) 远端 VPS 原生二进制一键安装、升级与运维综合管理工具箱。

## ✨ 功能特性

### 1. 全新一键安装部署
- **CPA 快速原生安装**：
  - 自动抓取 GitHub 最新可用 Release 二进制包（自动识别 GLIBC 默认动态插件版与 musl/OpenWrt `no-plugin` 静态便携版）；
  - 自动创建并注册 `systemctl --user` 守护服务，配置 `default.target` 实现开机常驻；
  - 自动补齐初始 `config.yaml` 配置文件与端口设置（默认 `:8317`）。
- **CPAMP 面板标准化安装**：
  - 自动对齐官方一键安装器（`install-cpamp.sh`）进行原生标准部署；
  - 自动配置 `run.sh` 启动脚本、PID 管理与数据目录隔离。

### 2. 智能版本升级维护
- **动态资产名匹配与空壳 Release 自动回退**：
  - 自动从 GitHub Releases 列表动态匹配匹配当前架构（`amd64`/`x86_64`、`aarch64`/`arm64`）与变体（`default` / `no-plugin`）的真实安装包名与下载链接，兼容上游包名格式变更；
  - **防上游 CI 失败 404**：当上游最新 Release 标签（如正在打包或 GitHub Actions 构建失败导致无预编译包的空壳 Release）缺失对应平台二进制时，自动告警并平滑回退至最新可用 Release 版本；
  - **双通道防限流**：优先通过 GitHub API 解析，遇匿名 API 限流（403）或无 Python 环境时自动切换 Web `expanded_assets` 通道解析。
- **本地版本比对与防重复下载**：
  - 自动探测本地已安装的 CPA / CPAMP 真实版本号并与远端最新可用版本比对；若本地已是最新可用版本，默认可一键跳过重复下载。
- **灵活备份策略**：
  - **备份后升级**：自动对二进制、配置文件、SQLite 数据库及 `data.key` 进行快照冷备，启动异常自动回滚。
  - **无备份直接升级 (小硬盘深度瘦身模式)**：
    - 升级时不生成额外的历史快照副本，并自动清理历史 `.bak.*` 二进制备份；
    - 升级成功并完成健康检查后，**自动清理 `runtime/` 历史版本残留目录**（只保留当前最新版本）；
    - **自动清空 `downloads/` 安装包缓存**，彻底释放硬盘空间！
- **5 级高容错路径探测**：
  - 优先从运行中进程（`/proc/<pid>/exe`）精准嗅探；
  - 自动从 systemd 配置解析 `ExecStart`；
  - 自动适配官方默认安装目录（`~/cliproxyapi/` 与 `~/cpa-manager-plus/`），并自动过滤 `/usr/local/bin/` 下的 Shell Wrapper 脚本；
  - 支持手动输入目录自动嗅探其内部二进制。
- **双模进程平滑热启**：
  - 优先采用 systemd 优雅停启；
  - 无 systemd 单元时无缝接管官方 `run.sh` 与 `cpa-manager-plus.pid`，无需手动改写服务配置。

### 3. 密钥自动提取与高亮大字报
- **CPA 安装/升级完成**：自动提取并在终端以高亮表格输出 **CPA Management Key** 与服务端口，方便后续直接对接面板。
- **CPAMP 安装/升级完成**：自动提取并在终端高亮输出 **CPAMP 管理员密钥** 与登录地址，避免在繁杂的日志中苦苦翻找。
- **全部安装完成**：自动汇总两大核心凭据，生成一目了然的凭据清单。

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
1. 智能版本升级 (支持 CPA/CPAMP、动态包名匹配、空 Release 自动回退、备份/无备份模式)
2. 全新一键安装 (支持 CPA 原生/守护、CPAMP 标准化安装、密钥大字报输出)
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
