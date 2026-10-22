#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI (CPA) & CPA Manager Plus (CPAMP) 一键部署与升级维护管理工具
# 支持架构：x86_64 (amd64) / aarch64 (arm64)
# 支持变体：GLIBC 默认版 (支持动态库插件) / musl & OpenWrt 便携版 (no-plugin)
# 支持服务管理：systemctl --user / sudo systemctl / run.sh nohup 进程管理
# 支持操作模式：全新一键安装部署 / 智能版本升级 (带备份/无备份)
# 核心容错：动态解析 Release 资产包名 + 上游空壳/构建失败 Release 自动回退
# 安装完成高亮展示：CPA Management Key 与 CPAMP 管理员密钥
# ==============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}====> $1 <====${NC}"; }
log_succ() { echo -e "${CYAN}[SUCCESS]${NC} $1"; }

# ------------------------------------------------------------------------------
# 1. 基础环境与架构检测
# ------------------------------------------------------------------------------
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        CPA_ARCH="amd64"
        CPAMP_ARCH="amd64"
        ARCH_REGEX="amd64|x86_64"
        ;;
    aarch64|arm64)
        CPA_ARCH="aarch64"
        CPAMP_ARCH="arm64"
        ARCH_REGEX="aarch64|arm64"
        ;;
    *)
        log_err "不支持的系统架构: $ARCH"
        exit 1
        ;;
esac

log_info "系统架构识别: $ARCH (CPA: $CPA_ARCH, CPAMP: $CPAMP_ARCH)"

# 检查常用基础命令
for cmd in curl tar grep awk sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_warn "缺少命令 $cmd，尝试自动安装..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -y && sudo apt-get install -y "$cmd"
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y "$cmd"
        fi
    fi
done

# GitHub 连通性与镜像加速检测
GH_PROXY=""
if ! curl -sI -m 3 https://api.github.com >/dev/null 2>&1; then
    log_warn "直接连接 GitHub API 超时，已启用镜像加速代理..."
    GH_PROXY="https://gh.jasonzeng.dev/"
fi

# ------------------------------------------------------------------------------
# 1.1 系统 libc / OpenWrt 变体检测与 Release 资产动态解析
# ------------------------------------------------------------------------------
is_openwrt_system() {
    [ -f /etc/openwrt_release ] && return 0
    if [ -f /etc/os-release ] && grep -qi 'openwrt' /etc/os-release 2>/dev/null; then
        return 0
    fi
    return 1
}

is_musl_system() {
    if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi 'musl'; then
        return 0
    fi
    [ -f /etc/alpine-release ] && return 0
    local loader
    for loader in /lib/ld-musl-*.so* /usr/lib/ld-musl-*.so*; do
        [ -e "$loader" ] && return 0
    done
    return 1
}

detect_cpa_asset_variant() {
    local cpa_dir="${1:-}"
    if [ -n "$cpa_dir" ] && [ -f "$cpa_dir/asset-variant.txt" ]; then
        local saved
        saved=$(tr -d '\r\n[:space:]' < "$cpa_dir/asset-variant.txt" 2>/dev/null || true)
        if [ "$saved" = "default" ] || [ "$saved" = "no-plugin" ]; then
            echo "$saved"
            return 0
        fi
    fi
    if is_openwrt_system || is_musl_system; then
        echo "no-plugin"
    else
        echo "default"
    fi
}

# 检查文件是否为真实二进制（排除 #! 开头的 shell wrapper 脚本）
is_real_binary() {
    local fpath="$1"
    [ -f "$fpath" ] || return 1
    local magic
    magic=$(head -c 2 "$fpath" 2>/dev/null || true)
    if [ "$magic" = "#!" ]; then
        return 1
    fi
    return 0
}

get_local_cpa_version() {
    local bin_path="${1:-}"
    local cpa_dir="${2:-}"
    local ver=""
    if [ -n "$bin_path" ] && [ -x "$bin_path" ]; then
        ver=$("$bin_path" -version 2>&1 | grep -oE 'CLIProxyAPI Version:[[:space:]]*v?[0-9]+\.[0-9]+\.[0-9]+([-a-zA-Z0-9.]*)?' | head -n 1 | awk '{print $NF}' | sed 's/^v//' || true)
    fi
    if [ -z "$ver" ] && [ -n "$cpa_dir" ] && [ -f "$cpa_dir/version.txt" ]; then
        ver=$(tr -d '\r\n[:space:]' < "$cpa_dir/version.txt" 2>/dev/null | sed 's/^v//' || true)
    fi
    echo "$ver"
}

get_local_cpamp_version() {
    local bin_path="${1:-}"
    local ver=""
    if [ -n "$bin_path" ] && [ -x "$bin_path" ]; then
        ver=$("$bin_path" --version 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+([-a-zA-Z0-9.]*)?' | head -n 1 | sed 's/^v//' || true)
    fi
    echo "$ver"
}

# 动态解析 GitHub 最新拥有可用二进制包的 Release
# 输出格式: RESOLVED_TAG|ASSET_NAME|DOWNLOAD_URL|FIRST_TAG
resolve_release_asset() {
    local repo="$1"
    local arch_regex="$2"
    local variant="${3:-default}"
    local api_url="${GH_PROXY}https://api.github.com/repos/${repo}/releases?per_page=10"
    local result=""

    # 通道 1: 通过 GitHub Releases API 扫描近期版本 (优先使用 python3 解析 JSON)
    local json_data
    json_data=$(curl -fsSL -m 15 -H "User-Agent: Mozilla/5.0" "$api_url" 2>/dev/null || true)
    if [ -n "$json_data" ] && command -v python3 >/dev/null 2>&1; then
        result=$(printf '%s' "$json_data" | python3 -c '
import sys, json, re
arch_re = sys.argv[1]
variant = sys.argv[2]
try:
    data = json.load(sys.stdin)
    if isinstance(data, dict):
        data = [data] if "tag_name" in data else []
    first_tag = data[0].get("tag_name", "") if data else ""
    for rel in data:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        tag = rel.get("tag_name", "")
        for a in rel.get("assets", []):
            name = a.get("name", "")
            dl = a.get("browser_download_url", "")
            lname = name.lower()
            if "linux" not in lname or not (lname.endswith(".tar.gz") or lname.endswith(".tgz")):
                continue
            if not re.search(rf"(^|[_.-])({arch_re})([_.-]|$)", lname):
                continue
            if variant == "no-plugin":
                if "no-plugin" not in lname:
                    continue
            else:
                if "no-plugin" in lname:
                    continue
            print(f"{tag}|{name}|{dl}|{first_tag}")
            sys.exit(0)
except Exception:
    pass
' "$arch_regex" "$variant" 2>/dev/null || true)
    fi

    if [ -n "$result" ]; then
        echo "$result"
        return 0
    fi

    # 通道 2: 免 API 配额兜底 (直接解析 GitHub Releases 页面与 expanded_assets)
    local releases_html
    releases_html=$(curl -fsSL -m 15 -H "User-Agent: Mozilla/5.0" "${GH_PROXY}https://github.com/${repo}/releases" 2>/dev/null || true)
    local tags_list=""
    if [ -n "$releases_html" ]; then
        tags_list=$(printf '%s' "$releases_html" | grep -oE "/${repo}/releases/tag/[^\"'?<> ]+" | sed "s|/${repo}/releases/tag/||" | awk '!seen[$0]++' | head -n 8 || true)
    fi

    if [ -z "$tags_list" ]; then
        local latest_Single
        latest_Single=$(curl -fsSL -m 10 -H "User-Agent: Mozilla/5.0" "${GH_PROXY}https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4 || true)
        tags_list="$latest_Single"
    fi

    local first_tag=""
    local t
    for t in $tags_list; do
        [ -z "$first_tag" ] && first_tag="$t"
        local assets_html
        assets_html=$(curl -fsSL -m 12 -H "User-Agent: Mozilla/5.0" "${GH_PROXY}https://github.com/${repo}/releases/expanded_assets/${t}" 2>/dev/null || true)
        [ -z "$assets_html" ] && continue

        local rel_paths
        rel_paths=$(printf '%s' "$assets_html" | grep -oE "/${repo}/releases/download/[^\"'?<> ]+" | awk '!seen[$0]++' || true)
        local rp
        for rp in $rel_paths; do
            local fname
            fname=$(basename "$rp")
            local lfname
            lfname=$(echo "$fname" | tr 'A-Z' 'a-z')
            echo "$lfname" | grep -q "linux" || continue
            echo "$lfname" | grep -qE '\.(tar\.gz|tgz)$' || continue
            echo "$lfname" | grep -qE "(^|[_.-])(${arch_regex})([_.-]|$)" || continue
            if [ "$variant" = "no-plugin" ]; then
                echo "$lfname" | grep -q "no-plugin" || continue
            else
                echo "$lfname" | grep -q "no-plugin" && continue
            fi
            echo "${t}|${fname}|https://github.com${rp}|${first_tag}"
            return 0
        done
    done

    return 1
}

# ------------------------------------------------------------------------------
# 2. 服务控制检测与进程启停辅助函数
# ------------------------------------------------------------------------------
detect_service_cmd() {
    local sname="$1"
    if systemctl --user list-unit-files 2>/dev/null | grep -q "$sname" || systemctl --user is-active "$sname" >/dev/null 2>&1; then
        echo "systemctl --user"
    elif systemctl list-unit-files 2>/dev/null | grep -q "$sname" || systemctl is-active "$sname" >/dev/null 2>&1; then
        echo "sudo systemctl"
    else
        echo "none"
    fi
}

extract_execstart_from_service() {
    local sname="$1"
    local svc_file=""
    
    for dir in "$HOME/.config/systemd/user" "/etc/systemd/user" "/usr/lib/systemd/user"; do
        if [ -f "$dir/$sname" ]; then
            svc_file="$dir/$sname"
            break
        fi
    done

    if [ -z "$svc_file" ]; then
        for dir in "/etc/systemd/system" "/lib/systemd/system" "/usr/lib/systemd/system"; do
            if [ -f "$dir/$sname" ]; then
                svc_file="$dir/$sname"
                break
            fi
        done
    fi

    if [ -n "$svc_file" ]; then
        local raw_exec
        raw_exec=$(grep -E '^\s*ExecStart=' "$svc_file" 2>/dev/null | head -n 1 | sed 's/^\s*ExecStart=//' || true)
        if [ -n "$raw_exec" ]; then
            local bin_path
            bin_path=$(echo "$raw_exec" | awk '{print $1}')
            bin_path="${bin_path#-}"
            bin_path="${bin_path%\"}"
            bin_path="${bin_path#\"}"
            if [ -f "$bin_path" ]; then
                echo "$bin_path"
                return 0
            fi
        fi
    fi
    return 1
}

# ------------------------------------------------------------------------------
# 3. 密钥读取与展示辅助
# ------------------------------------------------------------------------------
get_cpa_management_key() {
    local config_file="$1"
    if [ -f "$config_file" ]; then
        local raw
        raw=$(grep -A 5 -E '^[[:space:]]*remote-management:' "$config_file" 2>/dev/null | grep -E '^[[:space:]]*secret-key:' | head -n 1 || true)
        if [ -z "$raw" ]; then
            raw=$(grep -E '^[[:space:]]*secret-key:' "$config_file" 2>/dev/null | head -n 1 || true)
        fi
        echo "$raw" | awk -F':' '{print $2}' | tr -d ' "[:space:]' || true
    fi
}

get_cpamp_admin_key() {
    local base_dir="$1"
    local key=""
    # 1. 官方标准路径 secrets/cpamp-admin-key
    if [ -f "$base_dir/secrets/cpamp-admin-key" ]; then
        key=$(cat "$base_dir/secrets/cpamp-admin-key" 2>/dev/null | tr -d '\r\n ' || true)
    fi
    # 2. 从日志搜索生成的初始 admin key
    if [ -z "$key" ] && [ -f "$base_dir/cpa-manager-plus.log" ]; then
        key=$(grep -oE 'cmp_admin_[a-zA-Z0-9_-]+' "$base_dir/cpa-manager-plus.log" 2>/dev/null | tail -n 1 || true)
    fi
    echo "$key"
}

# ------------------------------------------------------------------------------
# 4. 全新一键安装模块
# ------------------------------------------------------------------------------

# 4.1 一键安装 CLIProxyAPI (CPA)
install_cpa() {
    log_step "开始全新安装 CLIProxyAPI (CPA)"

    local INSTALL_DIR="$HOME/cliproxyapi"
    read -r -p "请输入 CPA 安装目录 (默认: $INSTALL_DIR): " USER_DIR
    INSTALL_DIR="${USER_DIR:-$INSTALL_DIR}"
    INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
    mkdir -p "$INSTALL_DIR"

    local VARIANT
    VARIANT=$(detect_cpa_asset_variant "$INSTALL_DIR")
    log_info "目标资产变体: $VARIANT ($( [ "$VARIANT" = "no-plugin" ] && echo "musl/OpenWrt 便携静态版" || echo "GLIBC 标准版，支持动态库插件" ))"

    # 获取最新拥有可用资产包的 Release
    log_info "正在获取 CPA 最新可用 Release 版本与安装包..."
    local RESOLVED
    RESOLVED=$(resolve_release_asset "router-for-me/CLIProxyAPI" "$ARCH_REGEX" "$VARIANT" || true)
    if [ -z "$RESOLVED" ]; then
        log_err "获取 CPA 最新可用安装包失败，请检查网络或 GitHub 状态！"
        return 1
    fi

    local TAG PKG_NAME DOWNLOAD_URL LATEST_TAG
    TAG=$(echo "$RESOLVED" | cut -d'|' -f1)
    PKG_NAME=$(echo "$RESOLVED" | cut -d'|' -f2)
    DOWNLOAD_URL=$(echo "$RESOLVED" | cut -d'|' -f3)
    LATEST_TAG=$(echo "$RESOLVED" | cut -d'|' -f4)
    local CLEAN_VER="${TAG#v}"

    if [ -n "$LATEST_TAG" ] && [ "$LATEST_TAG" != "$TAG" ]; then
        log_warn "上游最新 Release ($LATEST_TAG) 暂无预编译二进制包 (可能构建失败或正在打包)，已自动选用最新可用版本: $TAG"
    fi
    log_info "CPA 目标版本: $TAG (安装包: $PKG_NAME)"

    local TMP_DIR
    TMP_DIR=$(mktemp -d)

    log_info "正在下载: $PKG_NAME ..."
    if ! curl -fSL --progress-bar "${GH_PROXY}${DOWNLOAD_URL}" -o "$TMP_DIR/$PKG_NAME"; then
        log_err "下载失败: $DOWNLOAD_URL"
        rm -rf "$TMP_DIR"
        return 1
    fi

    log_info "解压并安装二进制..."
    tar -xzf "$TMP_DIR/$PKG_NAME" -C "$TMP_DIR"
    local NEW_BIN
    NEW_BIN=$(find "$TMP_DIR" -type f \( -name "CLIProxyAPI" -o -name "cli-proxy-api" \) | head -n 1)
    if [ -z "$NEW_BIN" ]; then
        log_err "解压包中未找到二进制文件！"
        rm -rf "$TMP_DIR"
        return 1
    fi

    cp -f "$NEW_BIN" "$INSTALL_DIR/cli-proxy-api"
    chmod +x "$INSTALL_DIR/cli-proxy-api"
    echo "$CLEAN_VER" > "$INSTALL_DIR/version.txt"
    echo "$VARIANT" > "$INSTALL_DIR/asset-variant.txt"

    # 生成随机强秘钥作为 CPA Management Key
    local GEN_CPA_KEY="cpa_$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 24 || date +%s%N | sha256sum | head -c 24)"

    # 检查并配置 config.yaml
    if [ ! -f "$INSTALL_DIR/config.yaml" ]; then
        log_info "生成初始配置文件: $INSTALL_DIR/config.yaml"
        local EXAMPLE_CONF
        EXAMPLE_CONF=$(find "$TMP_DIR" -type f -name "config.example.yaml" | head -n 1 || true)
        if [ -n "$EXAMPLE_CONF" ] && [ -f "$EXAMPLE_CONF" ]; then
            cp "$EXAMPLE_CONF" "$INSTALL_DIR/config.yaml"
            if grep -q "remote-management:" "$INSTALL_DIR/config.yaml"; then
                sed -i "/remote-management:/,/secret-key:/ s/secret-key:.*/secret-key: \"$GEN_CPA_KEY\"/" "$INSTALL_DIR/config.yaml" || true
                sed -i "/remote-management:/,/allow-remote:/ s/allow-remote:.*/allow-remote: true/" "$INSTALL_DIR/config.yaml" || true
            else
                cat << EOF_APPEND >> "$INSTALL_DIR/config.yaml"

remote-management:
  allow-remote: true
  secret-key: "$GEN_CPA_KEY"
EOF_APPEND
            fi
        else
            cat << EOF_CONFIG > "$INSTALL_DIR/config.yaml"
port: 8317
remote-management:
  allow-remote: true
  secret-key: "$GEN_CPA_KEY"
EOF_CONFIG
        fi
    fi

    # 注册 systemd --user 服务
    log_info "配置 systemd --user 用户级守护服务..."
    local USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$USER_SYSTEMD_DIR"
    cat << EOF_SVC > "$USER_SYSTEMD_DIR/cliproxyapi.service"
[Unit]
Description=CLIProxyAPI Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/cli-proxy-api
Restart=always
RestartSec=10
Environment=HOME=$HOME

[Install]
WantedBy=default.target
EOF_SVC

    systemctl --user daemon-reload || true
    systemctl --user enable cliproxyapi.service || true
    systemctl --user restart cliproxyapi.service || true

    rm -rf "$TMP_DIR"
    sleep 2

    local REAL_CPA_KEY
    REAL_CPA_KEY=$(get_cpa_management_key "$INSTALL_DIR/config.yaml")
    REAL_CPA_KEY="${REAL_CPA_KEY:-$GEN_CPA_KEY}"

    if systemctl --user is-active cliproxyapi.service >/dev/null 2>&1; then
        log_succ "🎉 CLIProxyAPI (CPA) $TAG 安装并启动成功！"
    else
        log_warn "CPA 已安装到 $INSTALL_DIR，但服务启动未通过，可检查 systemctl --user status cliproxyapi.service。"
    fi

    echo -e "\n${GREEN}==============================================================${NC}"
    echo -e "${BOLD}${CYAN}            CLIProxyAPI (CPA) 安装配置信息                    ${NC}"
    echo -e "${GREEN}==============================================================${NC}"
    echo -e "🔹 安装版本:            ${BOLD}${TAG} (${VARIANT})${NC}"
    echo -e "🔹 安装路径:            ${BOLD}${INSTALL_DIR}/cli-proxy-api${NC}"
    echo -e "🔹 配置文件:            ${BOLD}${INSTALL_DIR}/config.yaml${NC}"
    echo -e "🔹 服务监听端口:        ${BOLD}8317${NC}"
    echo -e "🔑 ${YELLOW}${BOLD}CPA Management Key:  ${RED}${BOLD}${REAL_CPA_KEY}${NC}"
    echo -e "${GREEN}==============================================================${NC}"
    echo -e "${YELLOW}提示: 请妥善保存该 Key，后续 CPAMP 面板对接 CPA 时需要填入此项。${NC}\n"
}

# 4.2 一键安装 CPA Manager Plus (CPAMP)
install_cpamp() {
    log_step "开始全新安装 CPA Manager Plus (CPAMP)"
    log_info "将调用官方最新的一键安装器进行标准化原生部署..."

    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    local INSTALLER_URL="https://raw.githubusercontent.com/seakee/CPA-Manager-Plus/main/bin/install-cpamp.sh"
    
    if ! curl -fsSL "${GH_PROXY}${INSTALLER_URL}" -o "$TMP_DIR/install-cpamp.sh"; then
        log_err "获取官方安装脚本失败: $INSTALLER_URL"
        rm -rf "$TMP_DIR"
        return 1
    fi

    chmod +x "$TMP_DIR/install-cpamp.sh"
    bash "$TMP_DIR/install-cpamp.sh"
    rm -rf "$TMP_DIR"

    # 安装完成后扫描 CPAMP 根目录与密钥
    local CPAMP_DIR=""
    for candidate in "$HOME/cpa-manager-plus" "/opt/cpa-manager-plus"; do
        if [ -d "$candidate" ]; then
            CPAMP_DIR="$candidate"
            break
        fi
    done

    if [ -n "$CPAMP_DIR" ]; then
        local ADMIN_KEY
        ADMIN_KEY=$(get_cpamp_admin_key "$CPAMP_DIR")
        echo -e "\n${GREEN}==============================================================${NC}"
        echo -e "${BOLD}${CYAN}         CPA Manager Plus (CPAMP) 部署配置信息                ${NC}"
        echo -e "${GREEN}==============================================================${NC}"
        echo -e "🔹 安装路径:            ${BOLD}${CPAMP_DIR}${NC}"
        echo -e "🔹 Web 面板端口:        ${BOLD}18317${NC} (http://<VPS_IP>:18317)"
        if [ -n "$ADMIN_KEY" ]; then
            echo -e "🔑 ${YELLOW}${BOLD}CPAMP 管理员密钥:    ${RED}${BOLD}${ADMIN_KEY}${NC}"
        else
            echo -e "🔑 ${YELLOW}${BOLD}CPAMP 管理员密钥:    ${NC}请查看 ${CPAMP_DIR}/secrets/cpamp-admin-key"
        fi
        echo -e "${GREEN}==============================================================${NC}"
        echo -e "${YELLOW}提示: 打开浏览器访问 :18317，使用此管理员密钥直接登录即可。${NC}\n"
    fi
}

# 4.3 一键安装全部套件
install_all() {
    log_step "准备安装全部套件 (CPA + CPAMP)"
    install_cpa
    install_cpamp

    # 汇总输出两大核心密钥
    local CPA_KEY
    CPA_KEY=$(get_cpa_management_key "$HOME/cliproxyapi/config.yaml")
    local CPAMP_KEY
    CPAMP_KEY=$(get_cpamp_admin_key "$HOME/cpa-manager-plus")

    echo -e "\n${GREEN}==============================================================${NC}"
    echo -e "${BOLD}${CYAN}       🎉 全部部署完成！核心凭证汇总清单 (请截图或保存)       ${NC}"
    echo -e "${GREEN}==============================================================${NC}"
    echo -e "🔑 ${YELLOW}${BOLD}1. CPA Management Key:    ${RED}${BOLD}${CPA_KEY:-未检测到}${NC}"
    echo -e "🔑 ${YELLOW}${BOLD}2. CPAMP 管理员密钥:       ${RED}${BOLD}${CPAMP_KEY:-未检测到}${NC}"
    echo -e "🔹 CPA 服务地址:             ${BOLD}http://127.0.0.1:8317${NC}"
    echo -e "🔹 CPAMP Web 访问地址:       ${BOLD}http://<VPS_IP>:18317${NC}"
    echo -e "${GREEN}==============================================================${NC}\n"
}

# ------------------------------------------------------------------------------
# 5. 智能升级模块 (含备份/无备份模式)
# ------------------------------------------------------------------------------

# 5.1 升级 CLIProxyAPI (CPA)
upgrade_cpa() {
    local DO_BACKUP="${1:-1}"
    log_step "准备升级 CLIProxyAPI (CPA)"
    if [ "$DO_BACKUP" = "1" ]; then
        log_info "当前备份模式: [已启用] 升级前备份旧二进制"
    else
        log_warn "当前备份模式: [已禁用] 无备份直接覆盖升级 (适合小硬盘 VPS)"
    fi

    local CPA_SVC_NAME="cliproxyapi.service"
    if ! systemctl --user list-unit-files 2>/dev/null | grep -q "cliproxyapi"; then
        if systemctl --user list-unit-files 2>/dev/null | grep -q "cli-proxy-api"; then
            CPA_SVC_NAME="cli-proxy-api.service"
        fi
    fi

    local CPA_BIN=""

    # 策略 1: 从正在运行的进程提取
    local PID_PATH
    PID_PATH=$(pgrep -f "cli-proxy-api|cliproxyapi|CLIProxyAPI" 2>/dev/null | head -n 1 || true)
    if [ -n "$PID_PATH" ]; then
        local EXE_LINK
        EXE_LINK=$(readlink -f "/proc/$PID_PATH/exe" 2>/dev/null || true)
        if [ -f "$EXE_LINK" ]; then
            CPA_BIN="$EXE_LINK"
            log_info "通过运行进程精准探测到 CPA: $CPA_BIN"
        fi
    fi

    # 策略 2: 从 systemd 配置提取
    if [ -z "$CPA_BIN" ]; then
        CPA_BIN=$(extract_execstart_from_service "$CPA_SVC_NAME" || extract_execstart_from_service "cliproxyapi.service" || extract_execstart_from_service "cli-proxy-api.service" || true)
        if [ -n "$CPA_BIN" ]; then
            log_info "通过 systemd 服务配置提取到 CPA: $CPA_BIN"
        fi
    fi

    # 策略 3: 从 PATH 命令直接获取
    if [ -z "$CPA_BIN" ]; then
        local path_cpa
        path_cpa=$(command -v cliproxyapi || command -v CLIProxyAPI || which cli-proxy-api 2>/dev/null || true)
        if [ -n "$path_cpa" ] && is_real_binary "$path_cpa"; then
            CPA_BIN="$path_cpa"
        fi
    fi

    # 策略 4: 常见默认路径扫描
    if [ -z "$CPA_BIN" ]; then
        local search_paths=(
            "$HOME/cliproxyapi/cli-proxy-api"
            "$HOME/cliproxyapi/CLIProxyAPI"
            "$HOME/cliproxyapi/cliproxyapi"
            "$HOME/bin/cliproxyapi"
            "$HOME/bin/cli-proxy-api"
            "$HOME/.local/bin/cliproxyapi"
            "$HOME/.local/bin/cli-proxy-api"
            "/usr/local/bin/cliproxyapi"
            "/usr/local/bin/cli-proxy-api"
            "/opt/cliproxyapi/cliproxyapi"
            "/opt/cliproxyapi/cli-proxy-api"
        )
        for p in "${search_paths[@]}"; do
            if is_real_binary "$p"; then CPA_BIN="$p"; break; fi
        done
    fi

    # 策略 5: 提示用户输入
    if [ -z "$CPA_BIN" ]; then
        read -r -p "未自动检测到 CPA 可执行文件路径，请输入路径 (可输入目录如 $HOME/cliproxyapi): " INPUT_PATH
        INPUT_PATH="${INPUT_PATH/#\~/$HOME}"
        if [ -d "$INPUT_PATH" ]; then
            for candidate in "cli-proxy-api" "CLIProxyAPI" "cliproxyapi"; do
                if [ -f "$INPUT_PATH/$candidate" ]; then
                    CPA_BIN="$INPUT_PATH/$candidate"
                    break
                fi
            done
        elif [ -f "$INPUT_PATH" ]; then
            CPA_BIN="$INPUT_PATH"
        fi
    fi

    if [ -z "$CPA_BIN" ] || [ ! -f "$CPA_BIN" ]; then
        log_err "未能定位到 CPA 可执行文件，跳过 CPA 升级。"
        return 1
    fi

    local CPA_DIR
    CPA_DIR=$(dirname "$CPA_BIN")
    local CTL
    CTL=$(detect_service_cmd "$CPA_SVC_NAME")
    local VARIANT
    VARIANT=$(detect_cpa_asset_variant "$CPA_DIR")
    local LOCAL_VER
    LOCAL_VER=$(get_local_cpa_version "$CPA_BIN" "$CPA_DIR")

    log_info "CPA 目标文件: $CPA_BIN"
    log_info "CPA 所在目录: $CPA_DIR"
    log_info "服务管理器:   $CTL $CPA_SVC_NAME"
    local DISP_CPA_VER="未知"
    [ -n "$LOCAL_VER" ] && DISP_CPA_VER="v$LOCAL_VER"
    log_info "本地当前版本: $DISP_CPA_VER (变体: $VARIANT)"

    log_info "正在获取 CPA 最新可用 Release 版本与资产包..."
    local RESOLVED
    RESOLVED=$(resolve_release_asset "router-for-me/CLIProxyAPI" "$ARCH_REGEX" "$VARIANT" || true)
    if [ -z "$RESOLVED" ]; then
        log_err "获取 CPA 最新可用版本失败！"
        return 1
    fi

    local TAG PKG_NAME DOWNLOAD_URL LATEST_TAG
    TAG=$(echo "$RESOLVED" | cut -d'|' -f1)
    PKG_NAME=$(echo "$RESOLVED" | cut -d'|' -f2)
    DOWNLOAD_URL=$(echo "$RESOLVED" | cut -d'|' -f3)
    LATEST_TAG=$(echo "$RESOLVED" | cut -d'|' -f4)
    local CLEAN_VER="${TAG#v}"

    if [ -n "$LATEST_TAG" ] && [ "$LATEST_TAG" != "$TAG" ]; then
        log_warn "上游最新 Release ($LATEST_TAG) 暂无预编译二进制包 (上游 Actions 编译失败或正在打包)，已自动回退至最新可用版本: $TAG"
    fi
    log_info "CPA 最新可用版本: $TAG (资产包: $PKG_NAME)"

    if [ -n "$LOCAL_VER" ] && [ "$LOCAL_VER" = "$CLEAN_VER" ]; then
        echo "$CLEAN_VER" > "$CPA_DIR/version.txt" 2>/dev/null || true
        echo "$VARIANT" > "$CPA_DIR/asset-variant.txt" 2>/dev/null || true
        log_succ "当前本地 CPA 已是最新可用版本 ($TAG)，无需重复升级！"
        local force_reinstall=""
        read -r -p "是否仍要强制重新下载并覆盖安装 CPA $TAG？[y/N] (默认 N): " force_reinstall
        if [[ ! "${force_reinstall:-N}" =~ ^[Yy]$ ]]; then
            if [ "$DO_BACKUP" = "0" ]; then
                rm -f "${CPA_BIN}".bak.* 2>/dev/null || true
            fi
            log_info "已跳过 CPA 重复下载。"
            return 0
        fi
    fi

    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    log_info "正在下载: $PKG_NAME ..."
    if ! curl -fSL --progress-bar "${GH_PROXY}${DOWNLOAD_URL}" -o "$TMP_DIR/$PKG_NAME"; then
        log_err "下载失败: $DOWNLOAD_URL"
        rm -rf "$TMP_DIR"
        return 1
    fi

    log_info "解压新版本..."
    tar -xzf "$TMP_DIR/$PKG_NAME" -C "$TMP_DIR"
    local NEW_BIN
    NEW_BIN=$(find "$TMP_DIR" -type f \( -name "CLIProxyAPI" -o -name "cli-proxy-api" \) | head -n 1)
    if [ -z "$NEW_BIN" ]; then
        log_err "解压包中未找到二进制文件！"
        rm -rf "$TMP_DIR"
        return 1
    fi
    chmod +x "$NEW_BIN"

    # 停止服务
    if [ "$CTL" != "none" ]; then
        log_info "停止服务: $CTL stop $CPA_SVC_NAME"
        $CTL stop "$CPA_SVC_NAME" || true
    else
        pkill -f "$(basename "$CPA_BIN")" || true
    fi

    # 备份旧版本（按需）
    local BACKUP_BIN="${CPA_BIN}.bak.$(date +%Y%m%d_%H%M%S)"
    if [ "$DO_BACKUP" = "1" ]; then
        log_info "备份旧二进制 -> $BACKUP_BIN"
        cp -a "$CPA_BIN" "$BACKUP_BIN"
    else
        log_info "跳过备份旧二进制..."
    fi

    # 替换二进制并同步元数据文件
    log_info "应用新版本二进制 -> $CPA_BIN"
    cp -f "$NEW_BIN" "$CPA_BIN"
    echo "$CLEAN_VER" > "$CPA_DIR/version.txt" 2>/dev/null || true
    echo "$VARIANT" > "$CPA_DIR/asset-variant.txt" 2>/dev/null || true

    # 重启并检查状态
    if [ "$CTL" != "none" ]; then
        log_info "拉起服务: $CTL start $CPA_SVC_NAME"
        $CTL start "$CPA_SVC_NAME"
        sleep 2
        if $CTL is-active "$CPA_SVC_NAME" >/dev/null 2>&1; then
            log_succ "✅ CPA 升级至 $TAG 成功并已正常运行！"
            if [ "$DO_BACKUP" = "0" ]; then
                rm -f "${CPA_BIN}".bak.* 2>/dev/null || true
                if [ -d "$CPA_DIR/config_backup" ]; then
                    rm -rf "$CPA_DIR/config_backup"/* 2>/dev/null || true
                fi
            fi
        else
            log_err "❌ CPA 服务启动异常！"
            if [ "$DO_BACKUP" = "1" ] && [ -f "$BACKUP_BIN" ]; then
                log_warn "正在自动回滚至旧版本..."
                cp -f "$BACKUP_BIN" "$CPA_BIN"
                $CTL start "$CPA_SVC_NAME"
                log_warn "已回滚至旧版本。"
            fi
        fi
    else
        nohup "$CPA_BIN" >/dev/null 2>&1 &
        sleep 2
        log_succ "✅ CPA 二进制已更新至 $TAG 并重新启动！"
    fi

    rm -rf "$TMP_DIR"

    # 输出 Management Key
    local CPA_KEY
    CPA_KEY=$(get_cpa_management_key "$CPA_DIR/config.yaml")
    if [ -n "$CPA_KEY" ]; then
        echo -e "\n🔑 ${YELLOW}${BOLD}当前 CPA Management Key:  ${RED}${BOLD}${CPA_KEY}${NC}\n"
    fi
}

# 5.2 升级 CPA Manager Plus (CPAMP)
upgrade_cpamp() {
    local DO_BACKUP="${1:-1}"
    log_step "准备升级 CPA Manager Plus (CPAMP)"
    if [ "$DO_BACKUP" = "1" ]; then
        log_info "当前备份模式: [已启用] 升级前快照备份 (SQLite/密钥/配置)"
    else
        log_warn "当前备份模式: [已禁用] 无备份直接升级 (适合小硬盘 VPS)"
    fi

    local CPAMP_SVC_NAME="cpa-manager-plus.service"
    local CPAMP_BIN=""
    local CPAMP_BASE_DIR=""

    # 探测函数：给定一个候选根目录，提取有效基准目录与二进制路径
    resolve_from_base_dir() {
        local bdir="$1"
        bdir="${bdir%/}"
        [ -d "$bdir" ] || return 1

        # 检查是否本身就是 runtime/package 目录
        if is_real_binary "$bdir/cpa-manager-plus"; then
            CPAMP_BIN="$bdir/cpa-manager-plus"
            if [ -f "$bdir/../../run.sh" ]; then
                CPAMP_BASE_DIR=$(readlink -f "$bdir/../..")
            elif [ -f "$bdir/run.sh" ]; then
                CPAMP_BASE_DIR="$bdir"
            else
                CPAMP_BASE_DIR="$bdir"
            fi
            return 0
        fi

        # 检查 run.sh
        if [ -f "$bdir/run.sh" ]; then
            CPAMP_BASE_DIR="$bdir"
            local target_dir
            target_dir=$(grep -E '^[[:space:]]*cd[[:space:]]+' "$bdir/run.sh" | awk '{print $2}' | tr -d '"' || true)
            if [ -n "$target_dir" ]; then
                case "$target_dir" in
                    /*) ;;
                    *) target_dir="$bdir/$target_dir" ;;
                esac
                if is_real_binary "$target_dir/cpa-manager-plus"; then
                    CPAMP_BIN="$target_dir/cpa-manager-plus"
                    return 0
                fi
            fi
        fi

        # 检查 runtime 目录下的所有 cpa-manager-plus 二进制
        local found
        found=$(find "$bdir" -type f -name "cpa-manager-plus" 2>/dev/null | head -n 1 || true)
        if [ -n "$found" ] && is_real_binary "$found"; then
            CPAMP_BIN="$found"
            CPAMP_BASE_DIR="$bdir"
            return 0
        fi

        # 如果存在官方结构标记（run.sh 或 data 目录），即认定为根目录
        if [ -f "$bdir/run.sh" ] || [ -d "$bdir/data" ] || [ -f "$bdir/cpa-manager-plus.pid" ]; then
            CPAMP_BASE_DIR="$bdir"
            return 0
        fi

        return 1
    }

    # 策略 1: 从正在运行的进程提取
    local PID_PATH
    PID_PATH=$(pgrep -f "cpa-manager-plus" 2>/dev/null | head -n 1 || true)
    if [ -n "$PID_PATH" ]; then
        local EXE_LINK
        EXE_LINK=$(readlink -f "/proc/$PID_PATH/exe" 2>/dev/null || true)
        if is_real_binary "$EXE_LINK"; then
            CPAMP_BIN="$EXE_LINK"
            log_info "通过运行进程精准探测到 CPAMP: $CPAMP_BIN"
            local edir
            edir=$(dirname "$CPAMP_BIN")
            if [ -f "$edir/../../run.sh" ]; then
                CPAMP_BASE_DIR=$(readlink -f "$edir/../..")
            elif [ -f "$edir/run.sh" ]; then
                CPAMP_BASE_DIR="$edir"
            else
                CPAMP_BASE_DIR="$edir"
            fi
        fi
    fi

    # 策略 2: 从 systemd 配置提取
    if [ -z "$CPAMP_BIN" ]; then
        local svc_bin
        svc_bin=$(extract_execstart_from_service "$CPAMP_SVC_NAME" || true)
        if [ -n "$svc_bin" ] && is_real_binary "$svc_bin"; then
            CPAMP_BIN="$svc_bin"
            log_info "通过 systemd 服务配置提取到 CPAMP: $CPAMP_BIN"
            local sdir
            sdir=$(dirname "$CPAMP_BIN")
            if [ -f "$sdir/../../run.sh" ]; then
                CPAMP_BASE_DIR=$(readlink -f "$sdir/../..")
            else
                CPAMP_BASE_DIR="$sdir"
            fi
        fi
    fi

    # 策略 3: 从常见官方目录自动探测
    if [ -z "$CPAMP_BASE_DIR" ]; then
        for candidate_dir in "$HOME/cpa-manager-plus" "/root/cpa-manager-plus" "/opt/cpa-manager-plus" "$HOME/cpa-manager"; do
            if resolve_from_base_dir "$candidate_dir"; then
                log_info "自动识别到 CPAMP 目录: $CPAMP_BASE_DIR"
                break
            fi
        done
    fi

    # 策略 4: 从 PATH 获取 (严格过滤掉 shell wrapper 脚本)
    if [ -z "$CPAMP_BIN" ]; then
        local path_cmd
        path_cmd=$(command -v cpa-manager-plus || which cpa-manager-plus 2>/dev/null || true)
        if [ -n "$path_cmd" ] && is_real_binary "$path_cmd"; then
            CPAMP_BIN="$path_cmd"
            CPAMP_BASE_DIR=$(dirname "$path_cmd")
        fi
    fi

    # 策略 5: 提示用户输入
    if [ -z "$CPAMP_BASE_DIR" ] && [ -z "$CPAMP_BIN" ]; then
        read -r -p "未自动检测到 CPAMP 路径，请输入安装目录或文件 (例如 $HOME/cpa-manager-plus): " INPUT_PATH
        INPUT_PATH="${INPUT_PATH/#\~/$HOME}"
        INPUT_PATH="${INPUT_PATH%/}"
        if [ -d "$INPUT_PATH" ]; then
            resolve_from_base_dir "$INPUT_PATH" || true
        elif is_real_binary "$INPUT_PATH"; then
            CPAMP_BIN="$INPUT_PATH"
            CPAMP_BASE_DIR=$(dirname "$INPUT_PATH")
        fi
    fi

    # 校验是否定位成功
    if [ -z "$CPAMP_BASE_DIR" ] && [ -z "$CPAMP_BIN" ]; then
        log_err "未能定位到 CPAMP 安装路径或二进制，跳过 CPAMP 升级。"
        return 1
    fi

    # 如果只有 BASE_DIR 没有找到旧 BIN，尝试最终搜寻一次
    if [ -z "$CPAMP_BIN" ] && [ -n "$CPAMP_BASE_DIR" ]; then
        CPAMP_BIN=$(find "$CPAMP_BASE_DIR" -type f -name "cpa-manager-plus" 2>/dev/null | head -n 1 || true)
    fi

    local CTL
    CTL=$(detect_service_cmd "$CPAMP_SVC_NAME")
    local USE_RUN_SH=0
    if [ "$CTL" = "none" ]; then
        if [ -n "$CPAMP_BASE_DIR" ] && [ -f "$CPAMP_BASE_DIR/run.sh" ]; then
            USE_RUN_SH=1
            log_info "未注册 systemd 服务，检测到官方启动脚本: $CPAMP_BASE_DIR/run.sh"
        else
            log_warn "未检测到 systemd 服务也未找到 run.sh，将直接管理进程。"
        fi
    else
        log_info "检测到 systemd 服务管理方式: $CTL $CPAMP_SVC_NAME"
    fi

    local LOCAL_CPAMP_VER
    LOCAL_CPAMP_VER=$(get_local_cpamp_version "$CPAMP_BIN")

    log_info "CPAMP 项目根目录: ${CPAMP_BASE_DIR:-未知}"
    log_info "CPAMP 二进制文件: ${CPAMP_BIN:-待升级写入}"
    local DISP_CPAMP_VER="未知"
    [ -n "$LOCAL_CPAMP_VER" ] && DISP_CPAMP_VER="v$LOCAL_CPAMP_VER"
    log_info "CPAMP 本地版本:   $DISP_CPAMP_VER"

    # 获取最新拥有可用资产包的 Release
    log_info "正在获取 CPAMP 最新可用 Release 版本与资产包..."
    local RESOLVED
    RESOLVED=$(resolve_release_asset "seakee/CPA-Manager-Plus" "$ARCH_REGEX" "default" || true)
    if [ -z "$RESOLVED" ]; then
        log_err "获取 CPAMP 最新版本失败！"
        return 1
    fi

    local TAG PKG_NAME DOWNLOAD_URL LATEST_TAG
    TAG=$(echo "$RESOLVED" | cut -d'|' -f1)
    PKG_NAME=$(echo "$RESOLVED" | cut -d'|' -f2)
    DOWNLOAD_URL=$(echo "$RESOLVED" | cut -d'|' -f3)
    LATEST_TAG=$(echo "$RESOLVED" | cut -d'|' -f4)
    local CLEAN_VER="${TAG#v}"

    if [ -n "$LATEST_TAG" ] && [ "$LATEST_TAG" != "$TAG" ]; then
        log_warn "CPAMP 最新 Release ($LATEST_TAG) 暂无预编译包，已自动回退至最新可用版本: $TAG"
    fi
    log_info "CPAMP 最新可用版本: $TAG (资产包: $PKG_NAME)"

    if [ -n "$LOCAL_CPAMP_VER" ] && [ "$LOCAL_CPAMP_VER" = "$CLEAN_VER" ]; then
        log_succ "当前本地 CPAMP 已是最新可用版本 ($TAG)，无需重复升级！"
        local force_reinstall=""
        read -r -p "是否仍要强制重新下载并覆盖安装 CPAMP $TAG？[y/N] (默认 N): " force_reinstall
        if [[ ! "${force_reinstall:-N}" =~ ^[Yy]$ ]]; then
            log_info "已跳过 CPAMP 重复下载。"
            return 0
        fi
    fi

    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    log_info "正在下载: $PKG_NAME ..."
    if ! curl -fSL --progress-bar "${GH_PROXY}${DOWNLOAD_URL}" -o "$TMP_DIR/$PKG_NAME"; then
        log_err "下载失败: $DOWNLOAD_URL"
        rm -rf "$TMP_DIR"
        return 1
    fi

    log_info "解压新版本..."
    tar -xzf "$TMP_DIR/$PKG_NAME" -C "$TMP_DIR"
    local NEW_BIN
    NEW_BIN=$(find "$TMP_DIR" -type f -name "cpa-manager-plus" | head -n 1)
    if [ -z "$NEW_BIN" ]; then
        log_err "解压包中未找到 cpa-manager-plus 二进制！"
        rm -rf "$TMP_DIR"
        return 1
    fi
    chmod +x "$NEW_BIN"

    # 停止旧服务/进程
    if [ "$CTL" != "none" ]; then
        log_info "停止服务: $CTL stop $CPAMP_SVC_NAME"
        $CTL stop "$CPAMP_SVC_NAME" || true
    elif [ "$USE_RUN_SH" -eq 1 ] && [ -n "$CPAMP_BASE_DIR" ] && [ -f "$CPAMP_BASE_DIR/cpa-manager-plus.pid" ]; then
        local OLD_PID
        OLD_PID=$(cat "$CPAMP_BASE_DIR/cpa-manager-plus.pid" 2>/dev/null || true)
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" >/dev/null 2>&1; then
            log_info "停止原有 CPAMP 进程 (PID: $OLD_PID)..."
            kill "$OLD_PID" || true
            sleep 1
        fi
    else
        pkill -f "cpa-manager-plus" || true
    fi

    # 备份关键数据（按需）
    local BACKUP_DIR="${CPAMP_BASE_DIR:-/tmp}/backup_$(date +%Y%m%d_%H%M%S)"
    if [ "$DO_BACKUP" = "1" ] && [ -n "$CPAMP_BASE_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        log_info "正在冷备份 CPAMP 数据到 $BACKUP_DIR ..."
        if [ -n "$CPAMP_BIN" ] && [ -f "$CPAMP_BIN" ]; then
            cp -a "$CPAMP_BIN" "$BACKUP_DIR/" 2>/dev/null || true
        fi
        for d in "data" "secrets" "config.json"; do
            if [ -e "$CPAMP_BASE_DIR/$d" ]; then
                cp -a "$CPAMP_BASE_DIR/$d" "$BACKUP_DIR/" 2>/dev/null || true
            fi
        done
    else
        log_info "跳过冷备份数据以节省硬盘空间..."
    fi

    # 替换或安装文件
    log_info "应用新版本文件..."
    local EXTRACTED_TOP
    EXTRACTED_TOP=$(dirname "$NEW_BIN")
    local TARGET_DIR=""

    if [ -n "$CPAMP_BIN" ] && [ -f "$CPAMP_BIN" ]; then
        TARGET_DIR=$(dirname "$CPAMP_BIN")
        cp -f "$NEW_BIN" "$CPAMP_BIN"
        if [ -f "$EXTRACTED_TOP/cpa-manager-plusctl" ]; then
            cp -f "$EXTRACTED_TOP/cpa-manager-plusctl" "$TARGET_DIR/cpa-manager-plusctl" 2>/dev/null || true
            chmod +x "$TARGET_DIR/cpa-manager-plusctl" 2>/dev/null || true
        fi
    elif [ -n "$CPAMP_BASE_DIR" ]; then
        local RUNTIME_PKG="cpa-manager-plus_${TAG}_linux_${CPAMP_ARCH}"
        TARGET_DIR="$CPAMP_BASE_DIR/runtime/$RUNTIME_PKG"
        mkdir -p "$TARGET_DIR"
        cp -rf "$EXTRACTED_TOP/"* "$TARGET_DIR/"
        chmod +x "$TARGET_DIR/cpa-manager-plus"
        CPAMP_BIN="$TARGET_DIR/cpa-manager-plus"

        # 如果有 run.sh，更新其中的 cd 目标目录为最新 runtime
        if [ -f "$CPAMP_BASE_DIR/run.sh" ]; then
            sed -i -E "s|cd \".*runtime/cpa-manager-plus_.*\"|cd \"$TARGET_DIR\"|g" "$CPAMP_BASE_DIR/run.sh" || true
            sed -i -E "s|# CPAMP_RUNTIME_PACKAGE=.*|# CPAMP_RUNTIME_PACKAGE=$RUNTIME_PKG|g" "$CPAMP_BASE_DIR/run.sh" || true
        fi
    fi

    # 重启并检查状态
    log_info "重新启动 CPAMP..."
    if [ "$CTL" != "none" ]; then
        $CTL start "$CPAMP_SVC_NAME"
    elif [ "$USE_RUN_SH" -eq 1 ] && [ -n "$CPAMP_BASE_DIR" ]; then
        local LOG_FILE="$CPAMP_BASE_DIR/cpa-manager-plus.log"
        local PID_FILE="$CPAMP_BASE_DIR/cpa-manager-plus.pid"
        nohup "$CPAMP_BASE_DIR/run.sh" >> "$LOG_FILE" 2>&1 &
        local NEW_PID=$!
        echo "$NEW_PID" > "$PID_FILE"
        log_info "已通过 run.sh 启动 (PID: $NEW_PID, 日志: $LOG_FILE)"
    elif [ -n "$CPAMP_BIN" ] && [ -f "$CPAMP_BIN" ]; then
        nohup "$CPAMP_BIN" >/dev/null 2>&1 &
    fi

    sleep 3

    # 健康检查
    local HEALTH
    HEALTH=$(curl -s -m 3 http://127.0.0.1:18317/health 2>/dev/null || true)
    if [ -n "$HEALTH" ] || pgrep -f "cpa-manager-plus" >/dev/null 2>&1; then
        log_info "健康检查响应: ${HEALTH:-已正常运行}"
        log_succ "✅ CPAMP 升级至 $TAG 成功并已正常运行！"

        # 小硬盘极简模式：自动深度瘦身，清理 runtime 中的旧版本目录与 downloads 缓存
        if [ "$DO_BACKUP" = "0" ] && [ -n "$CPAMP_BASE_DIR" ]; then
            log_info "正在执行小硬盘专属瘦身清理..."
            if [ -d "$CPAMP_BASE_DIR/downloads" ]; then
                rm -rf "$CPAMP_BASE_DIR/downloads"/* 2>/dev/null || true
                log_info "已清理安装包缓存: $CPAMP_BASE_DIR/downloads"
            fi
            if [ -d "$CPAMP_BASE_DIR/runtime" ] && [ -n "$TARGET_DIR" ]; then
                local cleaned_count=0
                for old_ver in "$CPAMP_BASE_DIR"/runtime/*; do
                    if [ -d "$old_ver" ] && [ "$old_ver" != "$TARGET_DIR" ]; then
                        rm -rf "$old_ver" 2>/dev/null || true
                        cleaned_count=$((cleaned_count + 1))
                    fi
                done
                log_info "已自动清理 runtime 中 ${cleaned_count} 个旧版本残留目录，释放磁盘空间！"
            fi
        fi
    else
        log_err "❌ CPAMP 服务启动失败！"
        if [ "$DO_BACKUP" = "1" ] && [ -f "$BACKUP_DIR/cpa-manager-plus" ] && [ -n "$CPAMP_BIN" ]; then
            log_warn "正在自动回滚..."
            cp -f "$BACKUP_DIR/cpa-manager-plus" "$CPAMP_BIN"
            if [ "$CTL" != "none" ]; then
                $CTL start "$CPAMP_SVC_NAME"
            elif [ "$USE_RUN_SH" -eq 1 ]; then
                nohup "$CPAMP_BASE_DIR/run.sh" >> "$CPAMP_BASE_DIR/cpa-manager-plus.log" 2>&1 &
            fi
            log_warn "已回滚至备份版本。"
        fi
    fi

    rm -rf "$TMP_DIR"

    # 输出 Admin Key
    if [ -n "$CPAMP_BASE_DIR" ]; then
        local ADMIN_KEY
        ADMIN_KEY=$(get_cpamp_admin_key "$CPAMP_BASE_DIR")
        if [ -n "$ADMIN_KEY" ]; then
            echo -e "\n🔑 ${YELLOW}${BOLD}当前 CPAMP 管理员密钥:  ${RED}${BOLD}${ADMIN_KEY}${NC}\n"
        fi
    fi
}

# ------------------------------------------------------------------------------
# 6. 交互菜单与入口
# ------------------------------------------------------------------------------
prompt_backup_choice() {
    local target_name="$1"
    echo -e "\n${YELLOW}=== 请选择【${target_name}】升级模式 ===${NC}" >&2
    echo "1. 备份后升级 (推荐，安全有保障，升级前快照冷备，异常可自动回滚)" >&2
    echo "2. 无备份直接升级 (适合小硬盘 VPS，不生成备份，升级后自动瘦身清理旧版本)" >&2
    local sub_choice=""
    read -r -p "请选择升级模式 [1-2] (默认 1): " sub_choice
    sub_choice="${sub_choice:-1}"
    if [ "$sub_choice" = "2" ]; then
        echo "0"
    else
        echo "1"
    fi
}

menu_upgrade() {
    echo -e "\n${GREEN}---- 智能升级菜单 ----${NC}"
    echo "1. 升级全部 (CPA + CPAMP)"
    echo "2. 仅升级 CLIProxyAPI (CPA)"
    echo "3. 仅升级 CPA Manager Plus (CPAMP)"
    echo "4. 返回上一层"
    read -r -p "请选择升级目标 [1-4] (默认 1): " up_choice
    up_choice="${up_choice:-1}"

    case "$up_choice" in
        1)
            local DO_BACKUP
            DO_BACKUP=$(prompt_backup_choice "全部 (CPA + CPAMP)")
            upgrade_cpa "$DO_BACKUP"
            upgrade_cpamp "$DO_BACKUP"
            ;;
        2)
            local DO_BACKUP
            DO_BACKUP=$(prompt_backup_choice "CLIProxyAPI")
            upgrade_cpa "$DO_BACKUP"
            ;;
        3)
            local DO_BACKUP
            DO_BACKUP=$(prompt_backup_choice "CPA Manager Plus")
            upgrade_cpamp "$DO_BACKUP"
            ;;
        4)
            return 0
            ;;
        *)
            log_err "无效选项"
            ;;
    esac
}

menu_install() {
    echo -e "\n${GREEN}---- 全新安装部署菜单 ----${NC}"
    echo "1. 安装全部 (CPA + CPAMP 标准套件)"
    echo "2. 仅安装 CLIProxyAPI (CPA 网关)"
    echo "3. 仅安装 CPA Manager Plus (CPAMP 面板)"
    echo "4. 返回上一层"
    read -r -p "请选择安装目标 [1-4] (默认 1): " in_choice
    in_choice="${in_choice:-1}"

    case "$in_choice" in
        1)
            install_all
            ;;
        2)
            install_cpa
            ;;
        3)
            install_cpamp
            ;;
        4)
            return 0
            ;;
        *)
            log_err "无效选项"
            ;;
    esac
}

main() {
    echo -e "${GREEN}==============================================================${NC}"
    echo -e "${GREEN}      CLIProxyAPI & CPA Manager Plus 综合管理工具箱            ${NC}"
    echo -e "${GREEN}==============================================================${NC}"
    echo "1. 智能版本升级 (支持 CPA/CPAMP、动态包名匹配、空 Release 自动回退、备份/无备份模式)"
    echo "2. 全新一键安装 (支持 CPA 原生/守护、CPAMP 标准化安装、密钥大字报输出)"
    echo "3. 退出"
    read -r -p "请选择操作 [1-3] (默认 1): " main_choice
    main_choice="${main_choice:-1}"

    case "$main_choice" in
        1)
            menu_upgrade
            ;;
        2)
            menu_install
            ;;
        3)
            log_info "已退出。"
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
