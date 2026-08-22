#!/bin/bash
# ============================================================================
# 纯 IPv6 服务器 Cloudflare WARP 一键安装 + 管理菜单 (warpx)
# 支持 Debian/Ubuntu / CentOS/RHEL/Fedora
# 功能：
#   1. 修复 DNS（纯 IPv6 环境）
#   2. 安装依赖 (wireguard-tools, curl, resolvconf...)
#   3. 下载 wgcf 并注册 WARP 账户
#   4. 生成配置 (仅 IPv4 走 WARP)
#   5. 启动隧道 & 设置开机自启
#   6. 验证连通性
#   7. 安装 warpx 管理菜单（随时调出）
# ============================================================================

set -e

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# ---------- 检测系统 ----------
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION_ID="$VERSION_ID"
    else
        log_error "无法检测操作系统"
        exit 1
    fi

    case "$OS_ID" in
        debian|ubuntu)
            PKG_UPDATE="apt update -y"
            PKG_INSTALL="apt install -y"
            PKG_REMOVE="apt remove -y"
            RESOLVCONF_PKG="resolvconf"
            WIREGUARD_PKG="wireguard-tools"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                PKG_UPDATE="dnf check-update || true"
                PKG_INSTALL="dnf install -y"
                PKG_REMOVE="dnf remove -y"
            else
                PKG_UPDATE="yum check-update || true"
                PKG_INSTALL="yum install -y"
                PKG_REMOVE="yum remove -y"
            fi
            RESOLVCONF_PKG=""        # CentOS 没有 resolvconf 包，直接修改 /etc/resolv.conf
            WIREGUARD_PKG="wireguard-tools"
            # CentOS 可能需要 EPEL
            if ! rpm -q epel-release &>/dev/null; then
                log_info "安装 EPEL 仓库..."
                $PKG_INSTALL epel-release || true
            fi
            ;;
        *)
            log_error "不支持的系统: $OS_ID"
            exit 1
            ;;
    esac

    # 架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  WGCF_ARCH="linux_amd64" ;;
        aarch64) WGCF_ARCH="linux_arm64" ;;
        armv7l)  WGCF_ARCH="linux_armv7" ;;
        *)       log_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    log_info "系统: $OS_ID, 架构: $ARCH"
}

# ---------- 修复 DNS (纯 IPv6) ----------
fix_dns() {
    log_step "修复 DNS 配置（纯 IPv6 环境）..."

    if [ -f /etc/resolv.conf ] && [ ! -f /etc/resolv.conf.bak ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
        log_info "已备份 /etc/resolv.conf 到 /etc/resolv.conf.bak"
    fi

    cat > /etc/resolv.conf <<'EOF'
nameserver 2606:4700:4700::1111
nameserver 2606:4700:4700::1001
nameserver 2001:4860:4860::8888
options timeout:2 attempts:3
EOF
    log_info "DNS 已设为公共 IPv6 DNS"

    # 防止被覆盖（仅建议，不强制）
    if [ -f /etc/resolv.conf ] && [ -z "$(lsattr /etc/resolv.conf 2>/dev/null | grep 'i')" ]; then
        log_warn "为避免 DNS 被覆盖，可执行: chattr +i /etc/resolv.conf"
    fi

    # 测试解析
    if getent hosts api.cloudflareclient.com &>/dev/null; then
        log_info "DNS 解析测试通过"
    else
        log_warn "DNS 解析失败，请检查网络连通性"
        log_warn "可手动测试: getent hosts api.cloudflareclient.com"
    fi
}

# ---------- 安装依赖 ----------
install_deps() {
    log_step "安装依赖包..."
    eval $PKG_UPDATE || true
    # 安装基础工具
    eval $PKG_INSTALL curl wget dnsutils ca-certificates iproute2 iptables $RESOLVCONF_PKG $WIREGUARD_PKG 2>/dev/null || {
        log_warn "部分包安装失败，尝试单独安装..."
        eval $PKG_INSTALL curl wget dnsutils ca-certificates iproute iptables $WIREGUARD_PKG || true
    }
    log_info "依赖安装完成"
}

# ---------- 安装 wgcf ----------
install_wgcf() {
    log_step "安装 wgcf..."
    local version="2.2.32"
    local url="https://github.com/ViRb3/wgcf/releases/download/v${version}/wgcf_${version}_${WGCF_ARCH}"
    log_info "下载: $url"
    wget -q --show-progress -O /usr/local/bin/wgcf "$url"
    chmod +x /usr/local/bin/wgcf
    if wgcf --help &>/dev/null; then
        log_info "wgcf 安装成功"
    else
        log_error "wgcf 安装失败"
        exit 1
    fi
}

# ---------- 注册 & 生成配置 ----------
register_warp() {
    log_step "注册 WARP 账户..."
    cd /root

    if [ -f wgcf-account.toml ]; then
        log_warn "检测到已有账户文件，是否重新注册？"
        read -p "重新注册？(y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "使用已有账户"
        else
            rm -f wgcf-account.toml wgcf-profile.conf
        fi
    fi

    if [ ! -f wgcf-account.toml ]; then
        echo | wgcf register
        log_info "账户注册完成"
    fi

    log_step "生成 WireGuard 配置..."
    wgcf generate
    log_info "配置生成完成"

    # 修改 AllowedIPs 为仅 IPv4
    sed -i 's/^AllowedIPs = .*/AllowedIPs = 0.0.0.0\/0/' wgcf-profile.conf
    log_info "AllowedIPs 已设为仅 IPv4"

    # 安装到 /etc/wireguard/
    mkdir -p /etc/wireguard
    install -m 600 wgcf-profile.conf /etc/wireguard/warp4.conf
    log_info "配置文件已安装到 /etc/wireguard/warp4.conf"
}

# ---------- 启动 WARP ----------
start_warp() {
    log_step "启动 WARP 隧道..."

    if wg show warp4 &>/dev/null; then
        log_warn "warp4 已运行，正在重启..."
        wg-quick down warp4 2>/dev/null || true
        sleep 1
    fi

    wg-quick up warp4

    # 检查 IPv4 路由，若未自动添加则手动补
    if ! ip -4 route get 1.1.1.1 2>/dev/null | grep -q "dev warp4"; then
        log_warn "IPv4 路由未自动设置，手动添加..."
        ip route add default dev warp4 2>/dev/null || true
    fi

    log_info "WARP 启动完成"
}

# ---------- 开机自启 ----------
enable_autostart() {
    log_step "设置开机自启..."
    systemctl enable wg-quick@warp4 2>/dev/null && log_info "已启用开机自启" || log_warn "开机自启设置失败"
}

# ---------- 验证 ----------
verify_warp() {
    log_step "验证 WARP 状态..."
    echo ""
    echo "=== WireGuard 状态 ==="
    wg show warp4 2>/dev/null || echo "warp4 未运行"

    echo ""
    echo "=== IPv4 出口 (WARP) ==="
    curl -4 -s --max-time 5 ifconfig.me || echo "获取失败"

    echo ""
    echo "=== IPv4 WARP 检测 ==="
    curl -4 -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace | grep -E "warp|colo" || echo "检测失败"

    echo ""
    echo "=== IPv6 出口 (直连) ==="
    curl -6 -s --max-time 5 ifconfig.me || echo "获取失败"

    echo ""
    echo "=== IPv6 WARP 检测 (应显示 warp=off) ==="
    curl -6 -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace | grep warp || echo "检测失败"
}

# ---------- 安装 warpx 管理菜单 ----------
install_warpx() {
    log_step "安装 warpx 管理菜单..."
    cat > /usr/local/bin/warpx << 'EOF'
#!/bin/bash
# WARP 管理菜单 (由 warp_install.sh 自动生成)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

show_menu() {
    clear
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║       Cloudflare WARP 管理菜单          ║"
    echo "║       纯 IPv6 服务器 · 仅 IPv4 走 WARP  ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo "  ${GREEN}1${NC}. 启动 WARP"
    echo "  ${RED}2${NC}. 停止 WARP"
    echo "  ${BLUE}3${NC}. 查看状态"
    echo "  ${BLUE}4${NC}. 查看路由"
    echo "  ${YELLOW}5${NC}. 重启 WARP"
    echo "  ${BLUE}6${NC}. 验证连通性"
    echo "  ${BLUE}7${NC}. 查看日志"
    echo "  ${RED}8${NC}. 卸载 WARP"
    echo "  ${BLUE}0${NC}. 退出"
    echo ""
    echo -n "请选择 [0-8]: "
}

start_warp() {
    echo -e "${GREEN}▶ 启动 WARP...${NC}"
    wg-quick up warp4 2>&1
    ip route add default dev warp4 2>/dev/null || true
    echo -e "${GREEN}✓ 启动完成${NC}"
    read -p "按 Enter 返回..."
}

stop_warp() {
    echo -e "${RED}▶ 停止 WARP...${NC}"
    wg-quick down warp4 2>&1
    echo -e "${RED}✓ 已停止${NC}"
    read -p "按 Enter 返回..."
}

show_status() {
    echo -e "${BLUE}▶ WireGuard 状态${NC}"
    wg show warp4 2>/dev/null || echo -e "${YELLOW}warp4 未运行${NC}"
    echo ""
    echo -e "${BLUE}▶ IPv4 出口 IP${NC}"
    curl -4 -s --max-time 5 ifconfig.me || echo "获取失败"
    echo ""
    echo -e "${BLUE}▶ WARP 检测${NC}"
    curl -4 -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace | grep -E "warp|colo" || echo "检测失败"
    read -p "按 Enter 返回..."
}

show_routes() {
    echo -e "${BLUE}▶ IPv4 路由${NC}"
    ip -4 route | grep -E "default|warp4"
    echo ""
    echo -e "${BLUE}▶ IPv6 路由${NC}"
    ip -6 route | grep -E "default|warp4"
    echo ""
    echo -e "${BLUE}▶ 路由跟踪${NC}"
    echo -n "IPv4 → GitHub: "
    ip -4 route get 140.82.112.4 2>/dev/null | head -1 || echo "失败"
    echo -n "IPv6 → Cloudflare DNS: "
    ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -1 || echo "失败"
    read -p "按 Enter 返回..."
}

restart_warp() {
    echo -e "${YELLOW}▶ 重启 WARP...${NC}"
    wg-quick down warp4 2>/dev/null; sleep 1
    wg-quick up warp4 2>&1
    ip route add default dev warp4 2>/dev/null || true
    echo -e "${GREEN}✓ 重启完成${NC}"
    read -p "按 Enter 返回..."
}

verify_connectivity() {
    echo -e "${BLUE}▶ 连通性验证${NC}"
    echo -n "IPv4 出口 (WARP): "
    curl -4 -s --max-time 5 ifconfig.me || echo "失败"
    echo ""
    echo -n "IPv6 出口 (直连): "
    curl -6 -s --max-time 5 ifconfig.me || echo "失败"
    echo ""
    echo -n "IPv4 WARP 状态: "
    curl -4 -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace | grep warp || echo "失败"
    echo ""
    echo -n "IPv6 WARP 状态: "
    curl -6 -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace | grep warp || echo "失败"
    echo ""
    echo -n "GitHub IPv4 访问: "
    curl -4 -s -o /dev/null -w "%{http_code}" --max-time 5 https://github.com || echo "失败"
    read -p "按 Enter 返回..."
}

show_logs() {
    echo -e "${BLUE}▶ WARP 日志 (最近 50 行)${NC}"
    journalctl -u wg-quick@warp4 --no-pager -n 50
    read -p "按 Enter 返回..."
}

uninstall_warp() {
    echo -e "${RED}⚠ 确认卸载 WARP？${NC}"
    read -p "确认卸载？(y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && return
    echo -e "${RED}▶ 停止并卸载...${NC}"
    wg-quick down warp4 2>/dev/null
    systemctl disable wg-quick@warp4 2>/dev/null
    rm -f /etc/wireguard/warp4.conf
    rm -f /root/wgcf-account.toml /root/wgcf-profile.conf
    [ -f /etc/resolv.conf.bak ] && cp /etc/resolv.conf.bak /etc/resolv.conf
    echo -e "${GREEN}✓ 卸载完成${NC}"
    read -p "按 Enter 返回..."
}

while true; do
    show_menu
    read choice
    case $choice in
        1) start_warp ;;
        2) stop_warp ;;
        3) show_status ;;
        4) show_routes ;;
        5) restart_warp ;;
        6) verify_connectivity ;;
        7) show_logs ;;
        8) uninstall_warp ;;
        0) echo "退出"; exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
    esac
done
EOF
    chmod +x /usr/local/bin/warpx
    log_info "warpx 命令已安装，输入 'warpx' 即可调出管理菜单"
}

# ---------- 主流程 ----------
main() {
    # 检查 root
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 用户执行此脚本"
        exit 1
    fi

    echo ""
    echo "=================================================="
    echo "  纯 IPv6 服务器 Cloudflare WARP 一键安装"
    echo "  支持 Debian/Ubuntu / CentOS/RHEL/Fedora"
    echo "=================================================="
    echo ""

    detect_os
    fix_dns
    install_deps
    install_wgcf
    register_warp
    start_warp
    enable_autostart
    verify_warp
    install_warpx

    echo ""
    echo "=================================================="
    echo -e "${GREEN}✨ 全部完成！${NC}"
    echo "=================================================="
    echo ""
    echo "管理命令: warpx"
    echo "启动: wg-quick up warp4"
    echo "停止: wg-quick down warp4"
    echo "状态: wg show warp4"
    echo ""
    echo "验证: curl -4 ifconfig.me   # 应显示 WARP IPv4"
    echo "      curl -6 ifconfig.me   # 应显示 VPS 原生 IPv6"
    echo ""
}

main "$@"