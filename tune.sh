#!/usr/bin/env bash
# ==============================================================================
# 跨境 VPS 网络自适应智能调优脚本 (全地区通用版)
# 支持: 自动探测 RTT / 手动输入 RTT -> 自动计算 BDP -> 动态生成最优网络栈
# 适配系统: Debian 10+, Ubuntu 20.04+, CentOS 8+, Alpine 3.16+
# ==============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "错误: 必须以 root 权限运行此脚本！" >&2
   exit 1
fi

echo "=========================================================="
echo "    🚀 跨境 VPS 网络自适应智能调优向导"
echo "=========================================================="

# 1. 自动探测客户端 RTT
CLIENT_IP=$(echo "${SSH_CLIENT:-}" | awk '{print $1}')
[[ -z "$CLIENT_IP" ]] && CLIENT_IP=$(echo "${SSH_CONNECTION:-}" | awk '{print $1}')

DETECTED_RTT=""
if [[ -n "$CLIENT_IP" ]]; then
    echo -n "正在检测与当前客户端 ($CLIENT_IP) 的物理延迟... "
    PING_OUT=$(ping -c 3 -W 2 "$CLIENT_IP" 2>/dev/null | tail -n 1 || true)
    if [[ "$PING_OUT" =~ min/avg/max/mdev[[:space:]]*=[[:space:]]*[0-9.]+/([0-9.]+)/ ]]; then
        DETECTED_RTT=$(printf "%.0f" "${BASH_REMATCH[1]}")
        echo "探测成功: ${DETECTED_RTT} ms"
    else
        echo "客户端禁止 ICMP 回显，采用预设基准"
    fi
fi

# 2. 参数输入与交互处理 (支持命令行参数: ./tune.sh [RTT] [BANDWIDTH_MBPS])
INPUT_RTT="${1:-}"
INPUT_BW="${2:-}"

if [[ -z "$INPUT_RTT" ]]; then
    DEFAULT_RTT="${DETECTED_RTT:-50}"
    echo ""
    echo "常见延迟参考: 香港(45ms) | 日韩(70ms) | 美西(150ms) | 欧洲(200ms)"
    read -r -p "请输入到客户端的往返延迟 RTT (ms) [默认: ${DEFAULT_RTT}]: " USER_RTT
    RTT="${USER_RTT:-$DEFAULT_RTT}"
else
    RTT="$INPUT_RTT"
fi

if [[ -z "$INPUT_BW" ]]; then
    DEFAULT_BW="100"
    read -r -p "请输入期望保障的客户端上传带宽 (Mbps) [默认: 100]: " USER_BW
    BANDWIDTH_MBPS="${USER_BW:-$DEFAULT_BW}"
else
    BANDWIDTH_MBPS="$INPUT_BW"
fi

# 格式校验
if ! [[ "$RTT" =~ ^[0-9]+$ ]] || [[ "$RTT" -le 0 ]]; then
    echo "错误: 无效的 RTT 数值: $RTT" >&2
    exit 1
fi
if ! [[ "$BANDWIDTH_MBPS" =~ ^[0-9]+$ ]] || [[ "$BANDWIDTH_MBPS" -le 0 ]]; then
    echo "错误: 无效的带宽数值: $BANDWIDTH_MBPS" >&2
    exit 1
fi

echo ""
echo "===> [1/4] 计算 BDP 与网络协议栈参数..."
# BDP 字节数 = 带宽(Mbps) * 10^6 / 8 * RTT(ms) / 1000 = 带宽 * RTT * 125
BDP_BYTES=$(( BANDWIDTH_MBPS * RTT * 125 ))

# 初始接收缓冲 (考量 adv_win_scale=1 的 50% 开销 + 25% 裕量 => 2.5 * BDP)
CALC_DEFAULT_BUF=$(( BDP_BYTES * 5 / 2 ))
# 最小保底 2MB (2097152)，且向上按 512KB 对齐
MIN_BUF=2097152
if (( CALC_DEFAULT_BUF < MIN_BUF )); then
    RMEM_DEFAULT=$MIN_BUF
else
    RMEM_DEFAULT=$(( ((CALC_DEFAULT_BUF + 524287) / 524288) * 524288 ))
fi

# 读取机器物理内存，防止低配 VPS OOM
TOTAL_MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 1024)
if (( TOTAL_MEM_MB <= 1024 )); then
    # 1GB 及以下小内存 VPS: 最大缓冲限制在 16MB
    RMEM_MAX=16777216
elif (( TOTAL_MEM_MB <= 2048 )); then
    # 2GB 内存 VPS: 最大缓冲 32MB
    RMEM_MAX=33554432
else
    # 4GB+ 内存 VPS: 最大缓冲根据延迟自适应 32MB ~ 64MB
    if (( RTT >= 150 )); then
        RMEM_MAX=67108864
    else
        RMEM_MAX=33554432
    fi
fi
(( RMEM_MAX < RMEM_DEFAULT * 2 )) && RMEM_MAX=$(( RMEM_DEFAULT * 2 ))

# 根据 RTT 阶梯计算 notsent_lowat (消灭 Bufferbloat) 与 limit_output_bytes
if (( RTT < 70 )); then
    NOTSENT_LOWAT=16384     # 16KB
    LIMIT_OUTPUT=131072     # 128KB
elif (( RTT < 130 )); then
    NOTSENT_LOWAT=24576     # 24KB
    LIMIT_OUTPUT=196608     # 192KB
elif (( RTT < 180 )); then
    NOTSENT_LOWAT=32768     # 32KB
    LIMIT_OUTPUT=262144     # 256KB
else
    NOTSENT_LOWAT=65536     # 64KB
    LIMIT_OUTPUT=262144     # 256KB
fi

APPROX_INIT_WND_MB=$(awk "BEGIN {printf \"%.2f\", $RMEM_DEFAULT / 2 / 1048576}")
THEORY_MAX_MBPS=$(awk "BEGIN {printf \"%.1f\", ($RMEM_DEFAULT / 2 * 8) / ($RTT / 1000) / 1000000}")

echo "----------------------------------------------------------"
echo "物理延迟 RTT           : ${RTT} ms"
echo "目标保障带宽           : ${BANDWIDTH_MBPS} Mbps"
echo "计算物理 BDP           : $(( BDP_BYTES / 1024 )) KB"
echo "初始接收缓冲 (rmem)    : $(( RMEM_DEFAULT / 1024 / 1024 )) MB ($RMEM_DEFAULT bytes)"
echo "初始通告窗口 (rcv_wnd) : 约 ${APPROX_INIT_WND_MB} MB"
echo "起步吞吐物理上限       : 约 ${THEORY_MAX_MBPS} Mbps (无需等待扩窗)"
echo "最大缓冲上限 (max)     : $(( RMEM_MAX / 1024 / 1024 )) MB (已适配宿主机内存 ${TOTAL_MEM_MB}MB)"
echo "未发队列限制 (lowat)   : $(( NOTSENT_LOWAT / 1024 )) KB (防止 Bufferbloat)"
echo "排队单次限制 (output)  : $(( LIMIT_OUTPUT / 1024 )) KB"
echo "----------------------------------------------------------"

echo "===> [2/4] 备份原有 sysctl 配置..."
CONF_FILE="/etc/sysctl.d/99-bbr-proxy.conf"
[[ -f "$CONF_FILE" ]] && cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"

echo "===> [3/4] 写入动态调优内核配置..."
cat <<EOF > "$CONF_FILE"
# ══════════════════════════════════════════════════════════════
# TCP/IP & BBR 自适应动态调优配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 参数基准: RTT=${RTT}ms, 保障带宽=${BANDWIDTH_MBPS}Mbps, 宿主RAM=${TOTAL_MEM_MB}MB
# ══════════════════════════════════════════════════════════════

# 拥塞控制与队列调度
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 1. 核心关键：消除应用层 Bufferbloat
net.ipv4.tcp_notsent_lowat = ${NOTSENT_LOWAT}

# 2. 限制单套接字排队字节，让 fq pacing 发包均匀细腻
net.ipv4.tcp_limit_output_bytes = ${LIMIT_OUTPUT}

# 3. 核心关键：动态推导的初始接收/发送缓冲与弹性上限
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${RMEM_DEFAULT}
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${RMEM_MAX}
net.ipv4.tcp_rmem = 4096 ${RMEM_DEFAULT} ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${RMEM_DEFAULT} ${RMEM_MAX}

# 4. 连接队列扩展
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65535

# 5. TCP 状态回收与连接重用
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 180000

# 6. 空闲后恢复慢启动平滑探测 (避免打崩限速桶)
net.ipv4.tcp_slow_start_after_idle = 1

# 7. 孤儿与死连接快速释放
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_retries2 = 8

# 8. 快速保活探测
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# 9. 严禁开启 MTU Probing (避免丢包时误缩减 MSS 至 64 字节)
net.ipv4.tcp_mtu_probing = 0

# 10. 系统级句柄与优化
fs.file-max = 1048576
vm.swappiness = 10
net.ipv4.tcp_fastopen = 3
net.netfilter.nf_conntrack_max = 524288
EOF

sysctl --system >/dev/null

echo "===> [4/4] 重启代理服务让 Listening Socket 继承新缓冲区..."
SERVICES=("vless-singbox" "sing-box" "xray" "vless-xray" "hysteria-server" "trojan-go")
RESTARTED=0
for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "重启服务: $svc"
        systemctl restart "$svc"
        RESTARTED=1
    fi
done

[[ $RESTARTED -eq 0 ]] && echo "提示: 未检测到预设服务，请手动重启你的代理服务（如 sing-box/xray）。"

echo "=========================================================="
echo "✔ 自适应调优成功！请在客户端运行 Speedtest 验证测速。"
echo "=========================================================="
