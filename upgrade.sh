#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI (CPA) & CPA Manager Plus (CPAMP) 远端 VPS 一键升级脚本
# 支持架构：x86_64 (amd64) / aarch64 (arm64)
# 支持服务管理：systemctl --user / sudo systemctl / 自动探测
# ==============================================================================

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}====> $1 <====${NC}"; }

# ------------------------------------------------------------------------------
# 1. 基础环境与架构检测
# ------------------------------------------------------------------------------
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        CPA_ARCH="amd64"
        CPAMP_ARCH="amd64"
        ;;
    aarch64|arm64)
        CPA_ARCH="aarch64"
        CPAMP_ARCH="arm64"
        ;;
    *)
        log_err "不支持的系统架构: $ARCH"
        exit 1
        ;;
esac

log_info "系统架构识别: $ARCH (CPA: $CPA_ARCH, CPAMP: $CPAMP_ARCH)"

# 检查常用工具
for cmd in curl tar grep; do
    if ! command -v "$cmd" &>/dev/null; then
        log_warn "缺少命令 $cmd，尝试自动安装..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -y && sudo apt-get install -y "$cmd"
        elif command -v yum &>/dev/null; then
            sudo yum install -y "$cmd"
        fi
    fi
done

# GitHub 下载加速前缀选择 (国外直连，国内可选加速)
GH_PROXY=""
if ! curl -sI -m 3 https://api.github.com >/dev/null 2>&1; then
    log_warn "直接连接 GitHub API 超时，启用镜像加速代理..."
    GH_PROXY="https://gh.jasonzeng.dev/"
fi

# ------------------------------------------------------------------------------
# 2. 服务控制检测 (优先 user unit，其次 system unit)
# ------------------------------------------------------------------------------
detect_service_cmd() {
    local sname="$1"
    if systemctl --user is-enabled "$sname" &>/dev/null || systemctl --user is-active "$sname" &>/dev/null; then
        echo "systemctl --user"
    elif systemctl is-enabled "$sname" &>/dev/null || systemctl is-active "$sname" &>/dev/null; then
        echo "sudo systemctl"
    else
        echo "systemctl --user"
    fi
}

# ------------------------------------------------------------------------------
# 3. 升级 CLIProxyAPI (CPA)
# ------------------------------------------------------------------------------
upgrade_cpa() {
    log_step "准备升级 CLIProxyAPI (CPA)"

    # 自动探测 CPA 安装路径与服务名
    local CPA_BIN=$(command -v cliproxyapi || command -v CLIProxyAPI || which cli-proxy-api 2>/dev/null || true)
    if [ -z "$CPA_BIN" ]; then
        for p in "$HOME/bin/cliproxyapi" "$HOME/.local/bin/cliproxyapi" "/usr/local/bin/cliproxyapi" "/opt/cliproxyapi/cliproxyapi"; do
            if [ -f "$p" ]; then CPA_BIN="$p"; break; fi
        done
    fi

    if [ -z "$CPA_BIN" ]; then
        read -r -p "未自动检测到 CPA 可执行文件路径，请输入绝对路径 (例如 $HOME/bin/cliproxyapi): " CPA_BIN
    fi

    if [ ! -f "$CPA_BIN" ]; then
        log_err "文件不存在: $CPA_BIN，跳过 CPA 升级。"
        return 1
    fi

    local CPA_DIR=$(dirname "$CPA_BIN")
    local CPA_SVC_NAME="cliproxyapi.service"
    if ! systemctl --user list-unit-files 2>/dev/null | grep -q "cliproxyapi"; then
        if systemctl --user list-unit-files 2>/dev/null | grep -q "cli-proxy-api"; then
            CPA_SVC_NAME="cli-proxy-api.service"
        fi
    fi
    local CTL=$(detect_service_cmd "$CPA_SVC_NAME")

    log_info "CPA 目标路径: $CPA_BIN"
    log_info "服务管理器: $CTL $CPA_SVC_NAME"

    # 获取最新版本 tag
    log_info "正在获取 CPA 最新 Release 版本..."
    local LATEST_JSON=$(curl -sL "${GH_PROXY}https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest")
    local TAG=$(echo "$LATEST_JSON" | grep -Po '"tag_name":\s*"\K[^"]+' || true)
    if [ -z "$TAG" ]; then
        log_err "获取 CPA 最新版本失败！"
        return 1
    fi
    local CLEAN_VER="${TAG#v}"
    log_info "CPA 最新版本: $TAG"

    # 构造包名
    local PKG_NAME="CLIProxyAPI_${CLEAN_VER}_linux_${CPA_ARCH}.tar.gz"
    local DOWNLOAD_URL="https://github.com/router-for-me/CLIProxyAPI/releases/download/${TAG}/${PKG_NAME}"

    # 下载到临时目录
    local TMP_DIR=$(mktemp -d)
    log_info "正在下载: $PKG_NAME ..."
    if ! curl -fSL --progress-bar "${GH_PROXY}${DOWNLOAD_URL}" -o "$TMP_DIR/$PKG_NAME"; then
        log_err "下载失败: $DOWNLOAD_URL"
        rm -rf "$TMP_DIR"
        return 1
    fi

    log_info "解压新版本..."
    tar -xzf "$TMP_DIR/$PKG_NAME" -C "$TMP_DIR"
    local NEW_BIN=$(find "$TMP_DIR" -type f \( -name "CLIProxyAPI" -o -name "cliproxyapi" \) | head -n 1)
    if [ -z "$NEW_BIN" ]; then
        log_err "解压包中未找到二进制文件！"
        rm -rf "$TMP_DIR"
        return 1
    fi
    chmod +x "$NEW_BIN"

    # 停止服务并备份旧版本
    local BACKUP_BIN="${CPA_BIN}.bak.$(date +%Y%m%d_%H%M%S)"
    log_info "停止服务: $CTL stop $CPA_SVC_NAME"
    $CTL stop "$CPA_SVC_NAME" || true

    log_info "备份旧二进制 -> $BACKUP_BIN"
    cp -a "$CPA_BIN" "$BACKUP_BIN"

    # 替换
    log_info "应用新版本二进制..."
    cp -f "$NEW_BIN" "$CPA_BIN"

    # 重启并检查状态
    log_info "拉起服务: $CTL start $CPA_SVC_NAME"
    $CTL start "$CPA_SVC_NAME"
    sleep 2

    if $CTL is-active "$CPA_SVC_NAME" &>/dev/null; then
        log_info "✅ CPA 升级成功并已正常运行！"
    else
        log_err "❌ CPA 服务启动异常！正在自动回滚..."
        cp -f "$BACKUP_BIN" "$CPA_BIN"
        $CTL start "$CPA_SVC_NAME"
        log_warn "已回滚至旧版本。"
    fi

    rm -rf "$TMP_DIR"
}

# ------------------------------------------------------------------------------
# 4. 升级 CPA Manager Plus (CPAMP)
# ------------------------------------------------------------------------------
upgrade_cpamp() {
    log_step "准备升级 CPA Manager Plus (CPAMP)"

    # 自动检测 CPAMP 安装路径
    local CPAMP_BIN=$(command -v cpa-manager-plus || which cpa-manager-plus 2>/dev/null || true)
    if [ -z "$CPAMP_BIN" ]; then
        for p in "/opt/cpa-manager-plus/cpa-manager-plus" "$HOME/cpa-manager-plus/cpa-manager-plus" "$HOME/bin/cpa-manager-plus"; do
            if [ -f "$p" ]; then CPAMP_BIN="$p"; break; fi
        done
    fi

    if [ -z "$CPAMP_BIN" ]; then
        read -r -p "未自动检测到 CPAMP 可执行文件路径，请输入绝对路径 (例如 /opt/cpa-manager-plus/cpa-manager-plus): " CPAMP_BIN
    fi

    if [ ! -f "$CPAMP_BIN" ]; then
        log_err "文件不存在: $CPAMP_BIN，跳过 CPAMP 升级。"
        return 1
    fi

    local CPAMP_DIR=$(dirname "$CPAMP_BIN")
    local CPAMP_SVC_NAME="cpa-manager-plus.service"
    local CTL=$(detect_service_cmd "$CPAMP_SVC_NAME")

    log_info "CPAMP 目标路径: $CPAMP_BIN"
    log_info "CPAMP 所在目录: $CPAMP_DIR"
    log_info "服务管理器: $CTL $CPAMP_SVC_NAME"

    # 获取最新版本 tag
    log_info "正在获取 CPAMP 最新 Release 版本..."
    local LATEST_JSON=$(curl -sL "${GH_PROXY}https://api.github.com/repos/seakee/CPA-Manager-Plus/releases/latest")
    local TAG=$(echo "$LATEST_JSON" | grep -Po '"tag_name":\s*"\K[^"]+' || true)
    if [ -z "$TAG" ]; then
        log_err "获取 CPAMP 最新版本失败！"
        return 1
    fi
    log_info "CPAMP 最新版本: $TAG"

    local PKG_NAME="cpa-manager-plus_${TAG}_linux_${CPAMP_ARCH}.tar.gz"
    local DOWNLOAD_URL="https://github.com/seakee/CPA-Manager-Plus/releases/download/${TAG}/${PKG_NAME}"

    local TMP_DIR=$(mktemp -d)
    log_info "正在下载: $PKG_NAME ..."
    if ! curl -fSL --progress-bar "${GH_PROXY}${DOWNLOAD_URL}" -o "$TMP_DIR/$PKG_NAME"; then
        log_err "下载失败: $DOWNLOAD_URL"
        rm -rf "$TMP_DIR"
        return 1
    fi

    log_info "解压新版本..."
    tar -xzf "$TMP_DIR/$PKG_NAME" -C "$TMP_DIR"
    local NEW_BIN=$(find "$TMP_DIR" -type f -name "cpa-manager-plus" | head -n 1)
    if [ -z "$NEW_BIN" ]; then
        log_err "解压包中未找到 cpa-manager-plus 二进制！"
        rm -rf "$TMP_DIR"
        return 1
    fi
    chmod +x "$NEW_BIN"

    # 备份关键数据（数据库 + data.key + 配置文件）
    local BACKUP_DIR="${CPAMP_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    log_info "正在冷备份 CPAMP 数据到 $BACKUP_DIR ..."
    
    # 停止服务
    log_info "停止服务: $CTL stop $CPAMP_SVC_NAME"
    $CTL stop "$CPAMP_SVC_NAME" || true

    # 备份当前文件
    cp -a "$CPAMP_BIN" "$BACKUP_DIR/"
    if [ -d "$CPAMP_DIR/data" ]; then
        cp -a "$CPAMP_DIR/data" "$BACKUP_DIR/"
    fi
    if [ -f "$CPAMP_DIR/config.json" ]; then
        cp -a "$CPAMP_DIR/config.json" "$BACKUP_DIR/"
    fi
    if [ -d "/var/lib/cpa-manager-plus" ]; then
        cp -a "/var/lib/cpa-manager-plus" "$BACKUP_DIR/" 2>/dev/null || true
    fi

    # 替换二进制及配套静态资源 (保留原 config.json 和 data 目录不被覆盖)
    log_info "应用新版本文件..."
    local EXTRACTED_TOP=$(dirname "$NEW_BIN")
    if command -v rsync &>/dev/null; then
        rsync -av --exclude="config.json" --exclude="data" --exclude="*.sqlite*" "$EXTRACTED_TOP/" "$CPAMP_DIR/" 2>/dev/null || cp -f "$NEW_BIN" "$CPAMP_BIN"
    else
        cp -f "$NEW_BIN" "$CPAMP_BIN"
    fi

    # 重启并检查状态
    log_info "拉起服务: $CTL start $CPAMP_SVC_NAME"
    $CTL start "$CPAMP_SVC_NAME"
    sleep 3

    if $CTL is-active "$CPAMP_SVC_NAME" &>/dev/null; then
        local HEALTH=$(curl -s -m 3 http://127.0.0.1:18317/health 2>/dev/null || true)
        log_info "健康检查响应: ${HEALTH:-已连通}"
        log_info "✅ CPAMP 升级成功并已正常运行！"
    else
        log_err "❌ CPAMP 服务启动失败！正在自动回滚..."
        cp -f "$BACKUP_DIR/cpa-manager-plus" "$CPAMP_BIN"
        $CTL start "$CPAMP_SVC_NAME"
        log_warn "已回滚至备份版本。"
    fi

    rm -rf "$TMP_DIR"
}

# ------------------------------------------------------------------------------
# 5. 主入口菜单
# ------------------------------------------------------------------------------
main() {
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}    CLIProxyAPI & CPA Manager Plus 一键升级工具     ${NC}"
    echo -e "${GREEN}====================================================${NC}"
    echo "1. 升级全部 (CPA + CPAMP)"
    echo "2. 仅升级 CLIProxyAPI (CPA)"
    echo "3. 仅升级 CPA Manager Plus (CPAMP)"
    echo "4. 退出"
    read -r -p "请选择操作 [1-4] (默认 1): " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            upgrade_cpa
            upgrade_cpamp
            ;;
        2)
            upgrade_cpa
            ;;
        3)
            upgrade_cpamp
            ;;
        4)
            log_info "已取消。"
            exit 0
            ;;
        *)
            log_err "无效选项"
            exit 1
            ;;
    esac

    log_step "全部流程执行完毕"
}

main "$@"
