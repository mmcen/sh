cat > /tmp/swap.sh << 'EOF'
#!/bin/bash
# Swap 一键配置脚本 for Debian 12

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    Debian 12 Swap 一键配置脚本       ${NC}"
echo -e "${GREEN}========================================${NC}"

# 检查是否 root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用 root 权限运行: sudo bash $0${NC}"
    exit 1
fi

# 显示当前内存和 swap 状态
echo -e "\n${YELLOW}当前系统内存状态：${NC}"
free -h

# 检查是否已有 swap
EXISTING_SWAP=$(swapon --show)
if [ -n "$EXISTING_SWAP" ]; then
    echo -e "\n${YELLOW}检测到已存在的 Swap：${NC}"
    echo "$EXISTING_SWAP"
    read -p "是否要删除现有 Swap 并重新创建？(y/n): " REBUILD
    if [[ $REBUILD =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在关闭并删除现有 Swap...${NC}"
        for swapdev in $(swapon --show -n | awk '{print $1}'); do
            swapoff "$swapdev" 2>/dev/null || true
            if [[ "$swapdev" != /dev/* ]]; then
                rm -f "$swapdev" 2>/dev/null || true
            fi
        done
        # 清理 fstab 中的 swap 条目
        sed -i '/swap/d' /etc/fstab
        echo -e "${GREEN}现有 Swap 已清理${NC}"
    else
        echo -e "${GREEN}保留现有 Swap，退出脚本。${NC}"
        exit 0
    fi
fi

# 获取内存大小（GB）
MEM_TOTAL=$(free -g | awk '/^Mem:/{print $2}')
echo -e "\n${YELLOW}检测到物理内存: ${MEM_TOTAL}GB${NC}"

# 推荐大小
if [ $MEM_TOTAL -lt 2 ]; then
    DEFAULT_SWAP=2
    RECOMMEND="内存 < 2GB，推荐 2GB"
elif [ $MEM_TOTAL -le 8 ]; then
    DEFAULT_SWAP=2
    RECOMMEND="内存 ${MEM_TOTAL}GB，推荐 2GB"
elif [ $MEM_TOTAL -le 16 ]; then
    DEFAULT_SWAP=4
    RECOMMEND="内存 ${MEM_TOTAL}GB，推荐 4GB"
elif [ $MEM_TOTAL -le 64 ]; then
    DEFAULT_SWAP=4
    RECOMMEND="内存 ${MEM_TOTAL}GB，推荐 4GB"
else
    DEFAULT_SWAP=8
    RECOMMEND="内存 ${MEM_TOTAL}GB，推荐 8GB 或更多"
fi

echo -e "${GREEN}推荐 Swap 大小: ${RECOMMEND}${NC}"

# 用户输入大小
read -p "请输入 Swap 大小 (单位: GB, 默认 $DEFAULT_SWAP): " SWAP_SIZE_GB
SWAP_SIZE_GB=${SWAP_SIZE_GB:-$DEFAULT_SWAP}

# 验证输入
if ! [[ "$SWAP_SIZE_GB" =~ ^[0-9]+$ ]] || [ "$SWAP_SIZE_GB" -lt 1 ]; then
    echo -e "${RED}错误: 请输入有效的正整数（单位：GB）${NC}"
    exit 1
fi

SWAP_SIZE_MB=$((SWAP_SIZE_GB * 1024))
echo -e "\n${GREEN}将创建 ${SWAP_SIZE_GB}GB (${SWAP_SIZE_MB}MB) 的 Swap 文件${NC}"

# 检查磁盘空间
AVAIL=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
if [ $AVAIL -lt $((SWAP_SIZE_GB + 1)) ]; then
    echo -e "${RED}错误: 磁盘剩余空间不足 (剩余 ${AVAIL}GB, 需要 ${SWAP_SIZE_GB}GB)${NC}"
    exit 1
fi

# 创建 swap 文件
echo -e "\n${YELLOW}正在创建 /swapfile ...${NC}"
if command -v fallocate &> /dev/null; then
    fallocate -l ${SWAP_SIZE_GB}G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE_MB status=progress
else
    dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE_MB status=progress
fi

# 设置权限
chmod 600 /swapfile

# 格式化
mkswap /swapfile

# 启用
swapon /swapfile

# 写入 fstab
if ! grep -q "/swapfile" /etc/fstab; then
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

# 设置 swappiness
read -p "设置 swappiness 值 (默认 10, 范围 0-100): " SWAPPINESS
SWAPPINESS=${SWAPPINESS:-10}
if [[ "$SWAPPINESS" =~ ^[0-9]+$ ]] && [ $SWAPPINESS -ge 0 ] && [ $SWAPPINESS -le 100 ]; then
    sysctl vm.swappiness=$SWAPPINESS
    if grep -q "vm.swappiness" /etc/sysctl.conf; then
        sed -i "s/^vm.swappiness=.*/vm.swappiness=$SWAPPINESS/" /etc/sysctl.conf
    else
        echo "vm.swappiness=$SWAPPINESS" >> /etc/sysctl.conf
    fi
else
    echo -e "${YELLOW}输入无效，保持默认 10${NC}"
fi

# 显示结果
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Swap 配置完成！${NC}"
echo -e "${GREEN}========================================${NC}"
free -h
echo -e "\n${YELLOW}当前 Swap 状态:${NC}"
swapon --show
echo -e "\n${YELLOW}swappiness 值: $(cat /proc/sys/vm/swappiness)${NC}"
EOF

sudo bash /tmp/swap.sh && rm -f /tmp/swap.sh