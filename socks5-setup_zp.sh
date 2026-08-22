#!/bin/bash
#=============================================================================
#  SOCKS5 Proxy Server 一键安装管理脚本
#  支持: Ubuntu / Debian / CentOS (7/8/9) / Alpine
#  用法: bash socks5-setup.sh
#  安装后可使用 sk5 命令随时调出管理菜单
#=============================================================================

set -uo pipefail

# ===================== 全局变量 =====================
CONF_DIR="/etc/socks5"
CONF_FILE="${CONF_DIR}/socks5.conf"
USER_LIST="${CONF_DIR}/socks5.users"
SERVICE_NAME="socks5"
SK5_CMD="/usr/local/bin/sk5"
DANTE_VERSION="1.4.3"
DANTE_URL="https://github.com/inaetics/dante/releases/download/v${DANTE_VERSION}/dante-${DANTE_VERSION}.tar.gz"

DEFAULT_PORT="1080"
SOCKS5_PORT=""
SOCKS5_BIN=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ===================== 工具函数 =====================
info()    { echo -e "${GREEN}[信息]${NC} $1"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $1"; }
error()   { echo -e "${RED}[错误]${NC} $1"; exit 1; }
step()    { echo -e "${BLUE}  ▶${NC} $1"; }
success() { echo -e "${GREEN}  ✔${NC} $1"; }
separator(){ echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ===================== 系统检测 =====================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_VERSION="${VERSION_ID:-}"
        OS_NAME="${PRETTY_NAME:-}"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="centos"
        OS_VERSION=$(rpm -q --queryformat '%{VERSION}' centos-release 2>/dev/null || echo "7")
        OS_NAME=$(cat /etc/redhat-release)
    else
        error "无法识别的操作系统"
    fi

    case "${OS_ID}" in
        ubuntu|debian)              OS_FAMILY="debian" ;;
        centos|rhel|rocky|almalinux) OS_FAMILY="rhel"   ;;
        alpine)                    OS_FAMILY="alpine" ;;
        *)                         error "不支持的操作系统: ${OS_NAME}" ;;
    esac

    info "检测到系统: ${OS_NAME}"
}

# ===================== 权限检查 =====================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 用户运行此脚本"
    fi
}

# ===================== 获取脚本绝对路径（兼容 BusyBox） =====================
get_script_path() {
    local target="$1"
    cd "$(dirname "$target")" 2>/dev/null || return 1
    local basename
    basename="$(basename "$target")"
    if [ -L "$basename" ]; then
        local link="$(readlink "$basename")"
        get_script_path "$link"
    else
        echo "$(pwd)/${basename}"
    fi
}

# ===================== 安装依赖 =====================
install_deps() {
    case "${OS_FAMILY}" in
        debian)
            step "安装依赖..."
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || warn "apt update 失败，继续尝试安装"
            apt-get install -y -qq curl wget openssl >/dev/null 2>&1 || warn "部分依赖安装失败"
            success "依赖安装完成"
            ;;
        rhel)
            step "安装依赖..."
            if command -v dnf &>/dev/null; then
                dnf install -y -q curl wget tar openssl >/dev/null 2>&1 || warn "部分依赖安装失败"
            else
                yum install -y -q curl wget tar openssl >/dev/null 2>&1 || warn "部分依赖安装失败"
            fi
            success "依赖安装完成"
            ;;
        alpine)
            # shadow 包提供 useradd/userdel/chpasswd
            step "安装依赖..."
            apk add --no-cache shadow openssl 2>&1 || true
            success "依赖安装完成"
            ;;
    esac
}

# ===================== 安装 Dante =====================
install_dante_debian() {
    export DEBIAN_FRONTEND=noninteractive
    local output

    step "通过 apt 安装 dante-server..."
    output=$(apt-get install -y dante-server 2>&1)
    if [ $? -eq 0 ]; then
        SOCKS5_BIN="$(which sockd 2>/dev/null || echo '/usr/sbin/sockd')"
        success "dante-server 安装完成"
        return 0
    fi

    if echo "${output}" | grep -qi "unable to locate package"; then
        warn "apt 源中未找到 dante 包"
    else
        echo "${output}"
        warn "apt 安装失败，尝试源码编译..."
    fi

    install_dante_from_source
}

install_dante_from_source() {
    step "从源码编译安装 dante..."
    local work_dir="/tmp/dante-build"
    rm -rf "${work_dir}"
    mkdir -p "${work_dir}"
    cd "${work_dir}" || error "无法进入工作目录"

    step "安装编译依赖..."
    if [ "${OS_FAMILY}" = "debian" ]; then
        apt-get install -y gcc make curl wget tar 2>&1 | tail -2 || true
    else
        if command -v dnf &>/dev/null; then
            dnf install -y -q gcc make curl wget tar 2>&1 | tail -2
        else
            yum install -y -q gcc make curl wget tar 2>&1 | tail -2
        fi
    fi

    step "下载 dante v${DANTE_VERSION} 源码..."
    curl -sL "${DANTE_URL}" -o dante.tar.gz || error "下载 dante 源码失败"
    tar xzf dante.tar.gz || error "解压失败"
    cd "dante-${DANTE_VERSION}" || error "源码目录不存在"

    step "编译 dante（可能需要几分钟）..."
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
        --without-libwrap --without-pam 2>&1 | tail -1
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        error "configure 失败，请检查是否缺少依赖"
    fi
    make -j"$(nproc 2>/dev/null || echo 1)" >/dev/null 2>&1 || error "编译失败"
    make install >/dev/null 2>&1 || error "make install 失败"

    SOCKS5_BIN="/usr/sbin/sockd"
    cd /
    rm -rf "${work_dir}"
    success "dante 编译安装完成"
}

install_dante_rhel() {
    install_dante_from_source
}

install_dante_alpine() {
    step "通过 apk 安装 dante..."
    if ! apk add --no-cache dante 2>&1; then
        if ! apk add --no-cache dante-server 2>&1; then
            error "无法安装 dante，请检查 apk 源"
        fi
    fi
    SOCKS5_BIN="/usr/sbin/sockd"
    success "dante 安装完成"
}

install_dante() {
    separator
    case "${OS_FAMILY}" in
        debian) install_dante_debian  ;;
        rhel)   install_dante_rhel    ;;
        alpine) install_dante_alpine  ;;
    esac

    if [ ! -x "${SOCKS5_BIN}" ]; then
        error "sockd 二进制文件未找到: ${SOCKS5_BIN}"
    fi
    info "sockd 路径: ${SOCKS5_BIN}"
}

# ===================== 防火墙配置 =====================
setup_firewall() {
    local port="$1"
    step "配置防火墙放行端口 ${port}..."

    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null || true
    fi

    if command -v firewall-cmd &>/dev/null; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null || true
            firewall-cmd --permanent --add-port="${port}/udp" 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
        fi
    fi

    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -q "active"; then
            ufw allow "${port}/tcp" 2>/dev/null || true
            ufw allow "${port}/udp" 2>/dev/null || true
        fi
    fi

    success "防火墙配置完成"
}

# ===================== 配置文件生成 =====================
generate_config() {
    local port="$1"
    local ip_address ipv6_address

    ip_address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -z "${ip_address}" ] && ip_address="0.0.0.0"

    ipv6_address=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)

    mkdir -p "${CONF_DIR}"

    cat > "${CONF_FILE}" <<CONFEOF
# Dante SOCKS5 配置文件 - 由 socks5-setup.sh 生成

# 内网接口
internal: 0.0.0.0 port = ${port}
CONFEOF

    if [ -n "${ipv6_address}" ]; then
        echo "internal: :: port = ${port}" >> "${CONF_FILE}"
    fi

    cat >> "${CONF_FILE}" <<CONFEOF

# 外网出口
external: ${ip_address}
CONFEOF

    if [ -n "${ipv6_address}" ]; then
        echo "external: ${ipv6_address}" >> "${CONF_FILE}"
    fi

    cat >> "${CONF_FILE}" <<'CONFEOF'

# 日志输出
logoutput: /var/log/socks5.log

# SOCKS 会话认证方法（新版 Dante 关键字）
socksmethod: username

user.privileged: root
user.unprivileged: nobody

# 客户端连接规则（新版 Dante 关键字）
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

client block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}

# SOCKS 代理规则（新版 Dante 关键字）
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: error
}

socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}
CONFEOF

    touch "${USER_LIST}"
    chmod 600 "${USER_LIST}"

    success "配置文件已生成: ${CONF_FILE}"
}

# ===================== Systemd 服务 =====================
setup_systemd() {
    step "注册 systemd 服务..."

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=SOCKS5 Proxy Server (Dante)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SOCKS5_BIN} -f ${CONF_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    success "systemd 服务注册完成"
}

# ===================== OpenRC 服务 (Alpine) =====================
setup_openrc() {
    step "注册 OpenRC 服务..."

    printf '%s\n' \
        '#!/sbin/openrc-run' \
        '' \
        'name="socks5"' \
        'description="SOCKS5 Proxy Server (Dante)"' \
        "command=\"${SOCKS5_BIN}\"" \
        "command_args=\"-f ${CONF_FILE}\"" \
        'command_background=true' \
        'pidfile="/run/${RC_SVCNAME}.pid"' \
        'output_log="/var/log/socks5.log"' \
        'error_log="/var/log/socks5.err"' \
        '' \
        'depend() {' \
        '    need net' \
        '    after firewall' \
        '}' > "/etc/init.d/${SERVICE_NAME}"

    chmod +x "/etc/init.d/${SERVICE_NAME}"
    rc-update add "${SERVICE_NAME}" default 2>/dev/null || true
    success "OpenRC 服务注册完成"
}

# ===================== 服务管理 =====================
start_service() {
    if [ "${OS_FAMILY}" = "alpine" ]; then
        rc-service "${SERVICE_NAME}" start
    else
        systemctl start "${SERVICE_NAME}"
    fi
}

stop_service() {
    if [ "${OS_FAMILY}" = "alpine" ]; then
        rc-service "${SERVICE_NAME}" stop
    else
        systemctl stop "${SERVICE_NAME}"
    fi
}

restart_service() {
    if [ "${OS_FAMILY}" = "alpine" ]; then
        rc-service "${SERVICE_NAME}" restart
    else
        systemctl restart "${SERVICE_NAME}"
    fi
}

status_service() {
    if [ "${OS_FAMILY}" = "alpine" ]; then
        rc-service "${SERVICE_NAME}" status 2>&1 | head -1
    else
        systemctl is-active "${SERVICE_NAME}" 2>/dev/null
    fi
}

is_service_active() {
    local s
    s=$(status_service)
    case "${s}" in
        *started*|*active*|*running*) return 0 ;;
    esac
    return 1
}

show_service_log() {
    echo -e "${YELLOW}  最近日志:${NC}"
    if [ "${OS_FAMILY}" = "alpine" ]; then
        [ -f /var/log/socks5.err ] && tail -5 /var/log/socks5.err
        [ -f /var/log/socks5.log ] && tail -5 /var/log/socks5.log
    else
        journalctl -u "${SERVICE_NAME}" -n 10 --no-pager 2>/dev/null || true
    fi
}

# ===================== 获取当前端口 =====================
get_current_port() {
    if [ -f "${CONF_FILE}" ]; then
        sed -n 's/.*port[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "${CONF_FILE}" | head -1
    else
        echo "${DEFAULT_PORT}"
    fi
}

# ===================== 系统用户管理（Dante method: username 走 /etc/shadow） =====================
# SOCKS5 用户 = 系统用户，shell 设为 nologin 禁止登录

socks5_add_system_user() {
    local username="$1"
    local password="$2"

    if id "${username}" &>/dev/null; then
        # 用户已存在，更新密码
        echo "${username}:${password}" | chpasswd 2>/dev/null
    else
        # 创建新系统用户
        if [ "${OS_FAMILY}" = "alpine" ]; then
            adduser -D -s /sbin/nologin -h /dev/null -g "SOCKS5 user" "${username}" 2>/dev/null
        else
            useradd -r -s /usr/sbin/nologin -d /nonexistent -g "SOCKS5 user" "${username}" 2>/dev/null
        fi
        echo "${username}:${password}" | chpasswd 2>/dev/null
    fi
}

socks5_del_system_user() {
    local username="$1"
    if id "${username}" &>/dev/null; then
        if [ "${OS_FAMILY}" = "alpine" ]; then
            deluser "${username}" 2>/dev/null
        else
            userdel -r "${username}" 2>/dev/null
        fi
    fi
}

# ===================== 用户管理 =====================
add_user() {
    echo ""
    read -rp "  请输入新用户名: " new_user
    [ -z "${new_user}" ] && { warn "用户名不能为空"; return 1; }

    # 用户名合法性检查
    if ! echo "${new_user}" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_-]*$'; then
        warn "用户名只能包含字母、数字、下划线和连字符，且以字母或下划线开头"
        return 1
    fi

    if grep -q "^${new_user}$" "${USER_LIST}" 2>/dev/null; then
        warn "用户 '${new_user}' 已存在"
        read -rp "  是否覆盖密码？(y/n): " overwrite
        [ "${overwrite}" != "y" ] && [ "${overwrite}" != "Y" ] && return 0
    fi

    read -rp "  请输入密码: " new_pass
    [ -z "${new_pass}" ] && { warn "密码不能为空"; return 1; }

    # 创建/更新系统用户
    socks5_add_system_user "${new_user}" "${new_pass}"

    # 更新用户列表
    if grep -q "^${new_user}$" "${USER_LIST}" 2>/dev/null; then
        : # 已在列表中，无需重复添加
    else
        echo "${new_user}" >> "${USER_LIST}"
    fi
    chmod 600 "${USER_LIST}"

    success "用户 '${new_user}' 添加成功"
}

delete_user() {
    echo ""
    if [ ! -f "${USER_LIST}" ] || [ ! -s "${USER_LIST}" ]; then
        warn "当前没有已配置的用户"
        return 0
    fi

    echo -e "  ${BOLD}当前用户列表:${NC}"
    echo "  ─────────────────────"
    local idx=1
    local users=()
    while IFS= read -r user; do
        [ -z "${user}" ] && continue
        echo -e "  ${BLUE}[${idx}]${NC} ${user}"
        users+=("${user}")
        idx=$((idx + 1))
    done < "${USER_LIST}"
    echo "  ─────────────────────"

    read -rp "  请输入要删除的用户名或序号: " del_target
    [ -z "${del_target}" ] && { warn "未输入"; return 1; }

    local del_user="${del_target}"
    if [[ "${del_target}" =~ ^[0-9]+$ ]] && [ "${del_target}" -ge 1 ] && [ "${del_target}" -le ${#users[@]} ]; then
        del_user="${users[$((del_target-1))]}"
    fi

    if grep -q "^${del_user}$" "${USER_LIST}"; then
        sed -i "/^${del_user}$/d" "${USER_LIST}"
        socks5_del_system_user "${del_user}"
        success "用户 '${del_user}' 已删除"
    else
        warn "用户 '${del_user}' 不存在"
    fi
}

list_users() {
    echo ""
    if [ ! -f "${USER_LIST}" ] || [ ! -s "${USER_LIST}" ]; then
        warn "当前没有已配置的用户"
        return 0
    fi

    echo -e "  ${BOLD}SOCKS5 用户列表:${NC}"
    echo "  ┌──────────┬──────────────────────────────┐"
    echo -e "  │ ${BOLD}序号${NC}     │ ${BOLD}用户名${NC}                        │"
    echo "  ├──────────┼──────────────────────────────┤"
    local idx=1
    while IFS= read -r user; do
        [ -z "${user}" ] && continue
        echo -e "  │ ${CYAN}${idx}${NC}       │ ${user}                        │"
        idx=$((idx + 1))
    done < "${USER_LIST}"
    echo "  └──────────┴──────────────────────────────┘"
}

change_port() {
    local current_port
    current_port=$(get_current_port)
    echo ""
    read -rp "  当前端口: ${current_port}  新端口 (直接回车保持不变): " new_port

    if [ -n "${new_port}" ]; then
        if ! [[ "${new_port}" =~ ^[0-9]+$ ]] || [ "${new_port}" -lt 1 ] || [ "${new_port}" -gt 65535 ]; then
            warn "端口号无效，请输入 1-65535"
            return 1
        fi

        sed -i "s/port[[:space:]]*=[[:space:]]*[0-9]*/port = ${new_port}/g" "${CONF_FILE}"
        setup_firewall "${new_port}"
        success "端口已更改为 ${new_port}，正在重启服务..."
        restart_service
    fi
}

# ===================== 显示状态信息 =====================
show_status() {
    local port ip_address
    port=$(get_current_port)
    ip_address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -z "${ip_address}" ] && ip_address="N/A"

    echo ""
    separator
    echo -e "  ${BOLD}         SOCKS5 代理服务状态${NC}"
    separator
    echo -e "  状态:       $(is_service_active && echo -e "${GREEN}● 运行中${NC}" || echo -e "${RED}● 已停止${NC}")"
    echo -e "  监听端口:   ${CYAN}${port}${NC}"
    echo -e "  服务器 IP:  ${ip_address}"
    echo ""
    list_users

    # 如果服务停止，自动显示日志帮助排查
    if ! is_service_active; then
        echo ""
        show_service_log
    fi

    separator
}

# ===================== 主菜单 =====================
show_menu() {
    clear
    echo -e ""
    echo -e "  ${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "  ${BOLD}${CYAN}║${NC}       ${BOLD}SOCKS5 代理服务管理面板${NC}       ${BOLD}${CYAN}║${NC}"
    echo -e "  ${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}"
    echo -e ""
    echo -e "  ${BOLD}[1]${NC} 查看服务状态"
    echo -e "  ${BOLD}[2]${NC} 添加用户"
    echo -e "  ${BOLD}[3]${NC} 删除用户"
    echo -e "  ${BOLD}[4]${NC} 修改端口"
    echo -e "  ${BOLD}[5]${NC} 启动服务"
    echo -e "  ${BOLD}[6]${NC} 停止服务"
    echo -e "  ${BOLD}[7]${NC} 重启服务"
    echo -e "  ${BOLD}[8]${NC} 卸载 SOCKS5"
    echo -e "  ${BOLD}[0]${NC} 退出"
    echo -e ""
}

menu_loop() {
    while true; do
        show_menu
        read -rp "  请选择操作 [0-8]: " choice
        case "${choice}" in
            1) show_status  ;;
            2) add_user; restart_service ;;
            3) delete_user; restart_service ;;
            4) change_port ;;
            5)
                if start_service 2>&1; then
                    sleep 1
                    if is_service_active; then
                        success "服务已启动"
                    else
                        warn "服务启动后异常退出"
                        show_service_log
                    fi
                else
                    warn "服务启动失败"
                    show_service_log
                fi
                ;;
            6)
                stop_service 2>/dev/null
                if is_service_active; then warn "服务仍在运行"
                else success "服务已停止"; fi
                ;;
            7)
                if restart_service 2>&1; then
                    sleep 1
                    if is_service_active; then
                        success "服务已重启"
                    else
                        warn "服务重启后异常退出"
                        show_service_log
                    fi
                else
                    warn "服务重启失败"
                    show_service_log
                fi
                ;;
            8)
                echo ""
                read -rp "  确认卸载 SOCKS5？(y/n): " confirm
                if [ "${confirm}" = "y" ] || [ "${confirm}" = "Y" ]; then
                    uninstall
                fi
                ;;
            0|q|Q)
                echo -e "\n  再见！\n"
                exit 0
                ;;
            *)
                warn "无效选项，请重新选择"
                ;;
        esac
        echo -e ""
        read -rp "  按 Enter 键继续..."
    done
}

# ===================== 注册 sk5 命令 =====================
register_sk5_command() {
    step "注册 sk5 管理命令..."

    local script_path
    script_path=$(get_script_path "$0")
    [ -z "${script_path}" ] && script_path="$0"

    cat > "${SK5_CMD}" <<EOF
#!/bin/bash
# SOCKS5 管理命令 - 由 socks5-setup.sh 自动生成
bash "${script_path}" --menu
EOF

    chmod +x "${SK5_CMD}"
    success "sk5 命令已注册，随时输入 ${CYAN}sk5${NC} 即可打开管理面板"
}

# ===================== 卸载 =====================
uninstall() {
    step "停止服务..."
    stop_service 2>/dev/null || true

    step "禁用并移除服务..."
    if [ "${OS_FAMILY}" = "alpine" ]; then
        rc-update del "${SERVICE_NAME}" default 2>/dev/null || true
        rm -f "/etc/init.d/${SERVICE_NAME}"
    else
        systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload 2>/dev/null || true
    fi

    # 删除 SOCKS5 系统用户
    step "删除 SOCKS5 用户..."
    if [ -f "${USER_LIST}" ]; then
        while IFS= read -r user; do
            [ -z "${user}" ] && continue
            socks5_del_system_user "${user}"
        done < "${USER_LIST}"
    fi

    step "删除配置文件..."
    rm -rf "${CONF_DIR}"

    step "移除 sk5 命令..."
    rm -f "${SK5_CMD}"

    success "SOCKS5 已完全卸载"
    exit 0
}

# ===================== 首次安装流程 =====================
first_install() {
    separator
    echo -e "  ${BOLD}       SOCKS5 代理服务 - 安装向导${NC}"
    separator
    echo ""

    detect_os
    check_root

    read -rp "  请设置 SOCKS5 监听端口 (默认 ${DEFAULT_PORT}): " SOCKS5_PORT
    [ -z "${SOCKS5_PORT}" ] && SOCKS5_PORT="${DEFAULT_PORT}"
    if ! [[ "${SOCKS5_PORT}" =~ ^[0-9]+$ ]] || [ "${SOCKS5_PORT}" -lt 1 ] || [ "${SOCKS5_PORT}" -gt 65535 ]; then
        error "端口号无效，请输入 1-65535 之间的数字"
    fi

    echo ""
    read -rp "  请设置 SOCKS5 用户名: " FIRST_USER
    [ -z "${FIRST_USER}" ] && error "用户名不能为空"

    read -rp "  请设置 SOCKS5 密码:   " FIRST_PASS
    [ -z "${FIRST_PASS}" ] && error "密码不能为空"

    echo ""
    info "开始安装..."
    echo ""

    install_deps
    install_dante
    generate_config "${SOCKS5_PORT}"

    # 创建系统用户（Dante 走 /etc/shadow 认证）
    step "创建 SOCKS5 用户..."
    socks5_add_system_user "${FIRST_USER}" "${FIRST_PASS}"
    echo "${FIRST_USER}" > "${USER_LIST}"
    chmod 600 "${USER_LIST}"
    success "用户创建完成"

    setup_firewall "${SOCKS5_PORT}"

    if [ "${OS_FAMILY}" = "alpine" ]; then
        setup_openrc
    else
        setup_systemd
    fi

    if start_service 2>&1; then
        sleep 1
        if is_service_active; then
            : # OK
        else
            warn "服务启动后异常退出，请检查日志"
            show_service_log
        fi
    else
        warn "服务启动失败，请检查日志"
        show_service_log
    fi

    register_sk5_command

    echo ""
    separator
    echo -e "  ${GREEN}${BOLD}  ✔ SOCKS5 代理服务安装完成！${NC}"
    separator
    echo ""
    echo -e "  ${BOLD}连接信息:${NC}"
    local ip_address
    ip_address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    echo -e "    服务器:   ${CYAN}${ip_address}:${SOCKS5_PORT}${NC}"
    echo -e "    用户名:   ${CYAN}${FIRST_USER}${NC}"
    echo -e "    密码:     ${CYAN}${FIRST_PASS}${NC}"
    echo -e "    协议:     ${CYAN}SOCKS5${NC}"
    echo ""
    echo -e "  ${BOLD}管理命令:${NC}"
    echo -e "    ${CYAN}sk5${NC}  - 打开管理面板（添加/删除用户、修改端口等）"
    echo ""
    separator
}

# ===================== 主入口 =====================
main() {
    case "${1:-}" in
        --menu)
            check_root
            detect_os
            menu_loop
            ;;
        --uninstall)
            check_root
            detect_os
            uninstall
            ;;
        "")
            first_install
            ;;
        *)
            echo "用法: $0 [--menu] [--uninstall]"
            echo ""
            echo "  (无参数)       首次安装 SOCKS5 代理服务"
            echo "  --menu         打开管理面板（添加/删除用户等）"
            echo "  --uninstall    卸载 SOCKS5 代理服务"
            exit 1
            ;;
    esac
}

main "$@"