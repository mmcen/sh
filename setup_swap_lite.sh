#!/bin/bash
# 最简 Swap 配置脚本（集成彻底清理）

set -e

# 颜色（简单版）
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  768MB 小内存 Swap 一键配置          ${NC}"
echo -e "${GREEN}========================================${NC}"

# 检查 root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用 root 权限运行: sudo bash $0${NC}"
    exit 1
fi

# ========== 彻底清理已有的 Swap ==========
echo -e "\n${YELLOW}正在清理所有已有的 Swap...${NC}"

# 1. 关闭所有 swap（包括 /swapfile 和其他 swap 分区）
swapoff -a 2>/dev/null || true

# 2. 删除常见的 swap 文件
rm -f /swapfile 2>/dev/null || true

# 3. 清理 /etc/fstab 中所有包含 swap 的行（避免重启后再次挂载）
sed -i '/swap/d' /etc/fstab 2>/dev/null || true

echo -e "${GREEN}✓ 清理完成${NC}"

# ========== 显示当前状态 ==========
echo -e "\n${YELLOW}当前内存状态：${NC}"
free -h

# ========== 设置 Swap 大小 ==========
DEFAULT_SIZE=1536
echo -e "\n${YELLOW}物理内存约 768MB${NC}"
echo -e "${GREEN}推荐 Swap 大小: 1.5GB (1536MB)${NC}"
read -p "请输入 Swap 大小 (单位: MB, 默认 1536): " SWAP_SIZE_MB
SWAP_SIZE_MB=${SWAP_SIZE_MB:-$DEFAULT_SIZE}

# 验证输入
if ! [[ "$SWAP_SIZE_MB" =~ ^[0-9]+$ ]] || [ "$SWAP_SIZE_MB" -lt 512 ]; then
    echo -e "${RED}错误: 请输入有效数字（≥512）${NC}"
    exit 1
fi

# 计算 GB（用于显示）
SWAP_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $SWAP_SIZE_MB/1024}")
echo -e "\n${GREEN}将创建 ${SWAP_SIZE_MB}MB (约 ${SWAP_SIZE_GB}GB) 的 Swap 文件${NC}"

# 检查磁盘空间
AVAIL=$(df -m / | awk 'NR==2 {print $4}')
if [ -n "$AVAIL" ] && [ "$AVAIL" -lt $((SWAP_SIZE_MB + 200)) ]; then
    echo -e "${RED}错误: 磁盘剩余空间不足 (剩余 ${AVAIL}MB, 需要 ${SWAP_SIZE_MB}MB)${NC}"
    exit 1
fi

# ========== 创建 Swap 文件 ==========
echo -e "\n${YELLOW}正在创建 /swapfile ...${NC}"
# 优先用 fallocate，不行再用 dd
if command -v fallocate &> /dev/null; then
    fallocate -l ${SWAP_SIZE_MB}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE_MB status=progress
else
    dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE_MB status=progress
fi

chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# ========== 写入 fstab 永久生效 ==========
echo "/swapfile none swap sw 0 0" >> /etc/fstab

# ========== 设置 swappiness ==========
echo -e "\n${YELLOW}设置 swappiness (小内存建议 80)${NC}"
read -p "输入 swappiness 值 (0-100, 默认 80): " SWAPPINESS
SWAPPINESS=${SWAPPINESS:-80}
if [[ "$SWAPPINESS" =~ ^[0-9]+$ ]] && [ $SWAPPINESS -ge 0 ] && [ $SWAPPINESS -le 100 ]; then
    sysctl vm.swappiness=$SWAPPINESS
    # 写入 sysctl.conf
    grep -q "vm.swappiness" /etc/sysctl.conf && sed -i "s/^vm.swappiness=.*/vm.swappiness=$SWAPPINESS/" /etc/sysctl.conf || echo "vm.swappiness=$SWAPPINESS" >> /etc/sysctl.conf
else
    echo -e "${YELLOW}输入无效，使用默认 80${NC}"
    sysctl vm.swappiness=80
    echo "vm.swappiness=80" >> /etc/sysctl.conf
fi

# 额外优化（可选）
echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
sysctl vm.vfs_cache_pressure=50

# ========== 显示结果 ==========
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Swap 配置完成！${NC}"
echo -e "${GREEN}========================================${NC}"
free -h
echo -e "\n${YELLOW}当前 Swap 状态:${NC}"
swapon --show 2>/dev/null || swapon -s
echo -e "\n${YELLOW}优化参数:${NC}"
echo "  vm.swappiness = $(cat /proc/sys/vm/swappiness)"
echo "  vm.vfs_cache_pressure = $(cat /proc/sys/vm/vfs_cache_pressure)"