# tune.sh

基于 RTT（往返时延）与目标带宽计算 Linux TCP 参数的调优脚本，用于解决代理场景下的两类问题：
1. 客户端向 VPS 上传速率受限（因接收端通告窗口 `rcv_wnd` 过小）。
2. VPS 向客户端发送数据时初始突发后断崖丢包与超时假死（因应用层缓冲区膨胀与令牌桶丢包）。

---

## 快速开始（一键指令）

以 `root` 权限在 VPS 执行：

### 1. 交互式（自动探测客户端 RTT，回车确认）
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cfm019/tune/main/tune.sh)
```

### 2. 非交互式（直接指定 RTT 与保障带宽）
```bash
# 语法：bash <(curl -fsSL ...) [RTT(ms)] [Bandwidth(Mbps)]

# 示例：香港/亚太节点 (45ms RTT, 1000Mbps)
bash <(curl -fsSL https://raw.githubusercontent.com/cfm019/tune/main/tune.sh) 45 1000

# 示例：美西节点 (150ms RTT, 1000Mbps)
bash <(curl -fsSL https://raw.githubusercontent.com/cfm019/tune/main/tune.sh) 150 1000
```

---

## 一、 参数计算原理

### 1. 物理模型与吞吐上限

TCP 物理吞吐量受限于接收窗口与往返时延：

$$\text{Throughput} \le \frac{\text{Receive Window}}{\text{RTT}}$$

在 Linux 中，内核参数 `tcp_adv_win_scale` 默认为 1，即内核保留约 50% 的接收缓冲区用于 `sk_buff` 结构体及协议头开销，向对端通告的有效接收窗口约为实际分配缓冲区的一半：

$$\text{有效通告窗口} \approx \frac{\text{接收缓冲区}}{2}$$

当系统配置的默认接收缓冲（`tcp_rmem` 中间值）过小（例如默认的 87,380 字节）且应用未触发动态扩窗时，通告窗口仅约 41.5 KB。在 45ms RTT 下，物理吞吐上限为：

$$\frac{42496 \times 8}{0.045} \approx 7.55 \sim 9.5 \text{ Mbps}$$

客户端上传速度因此被硬性限制在 10 Mbps 以下。

---

### 2. 初始缓冲区推导

目标带宽（Bandwidth）与往返时延（RTT）的带宽时延积（BDP）计算公式：

$$\text{BDP (Bytes)} = \frac{\text{Bandwidth (Mbps)} \times 10^6}{8} \times \frac{\text{RTT (ms)}}{1000} = \text{Bandwidth} \times \text{RTT} \times 125$$

为使新建连接无需等待动态扩窗即可达到设定带宽，考虑 50% 开销与 25% 裕量，初始接收缓冲（`rmem_default`）设为：

$$\text{初始接收缓冲} = 2.5 \times \text{BDP}$$

保底值为 2 MB（2,097,152 字节），计算结果向上按 512 KB 对齐。

---

### 3. 各参数计算规则

| 参数 | 计算规则 / 取值依据 |
| :--- | :--- |
| `net.core.rmem_default`<br>`net.core.wmem_default` | 设为推导出的 `rmem_default`。 |
| `net.ipv4.tcp_rmem`<br>`net.ipv4.tcp_wmem` | 格式为 `4096 <rmem_default> <rmem_max>`。 |
| `net.core.rmem_max`<br>`net.core.wmem_max` | 依 VPS 内存调整：<br>• 内存 ≤ 1GB：16 MB<br>• 内存 ≤ 2GB：32 MB<br>• 内存 > 2GB 且 RTT ≥ 150ms：64 MB，其余 32 MB<br>且不小于 `rmem_default` 的 2 倍。 |
| `net.ipv4.tcp_notsent_lowat` | 限制套接字未发送队列，未发送数据低于该阈值才唤醒应用写入，防止缓冲区膨胀：<br>• RTT < 70ms：16 KB (16384)<br>• 70ms ≤ RTT < 130ms：24 KB (24576)<br>• 130ms ≤ RTT < 180ms：32 KB (32768)<br>• RTT ≥ 180ms：64 KB (65536) |
| `net.ipv4.tcp_limit_output_bytes` | 限制单套接字排队注入 qdisc 的字节量，配合 fq 进行 pacing：<br>• RTT < 70ms：128 KB (131072)<br>• 70ms ≤ RTT < 180ms：192 KB ~ 256 KB |
| `net.ipv4.tcp_slow_start_after_idle` | 固定为 `1`。连接空闲后重置为慢启动，防止突发流量冲撞中间节点限速策略。 |
| `net.ipv4.tcp_orphan_retries` | 固定为 `3`。加速回收已关闭但未完成四次挥手的套接字。 |
| `net.ipv4.tcp_retries2` | 固定为 `8`。缩短不可达连接的重传判定时间至约 1~2 分钟。 |
| `net.ipv4.tcp_keepalive_time` | 固定为 `300` 秒，探测间隔 `30` 秒，探测次数 `3` 次。 |
| `net.ipv4.tcp_mtu_probing` | 固定为 `0`。防止丢包误判导致 MSS 降至 64 字节。 |

---

## 二、 使用方法

### 1. 运行前提
* Linux 系统，内核版本 ≥ 4.9（需支持 BBR 与 fq）。
* 具有 `root` 权限。

---

### 2. 本地运行（克隆或下载脚本）
```bash
# 交互式
sudo bash tune.sh

# 非交互式
sudo bash tune.sh 45 1000
```

---

### 3. 远程执行（通过 SSH / bwssh）
```bash
# 通过标准 SSH
ssh root@<VPS_IP> "bash -s" < tune.sh 45 1000

# 通过 bwssh
~/.local/bin/bwssh <host-alias> "bash -s" < tune.sh 150 1000
```

---

### 4. 配置文件位置与回滚
* 配置文件写入路径：`/etc/sysctl.d/99-bbr-proxy.conf`
* 执行时自动在同目录生成备份：`/etc/sysctl.d/99-bbr-proxy.conf.bak.<时间戳>`
* 回滚方法：
  ```bash
  sudo cp /etc/sysctl.d/99-bbr-proxy.conf.bak.<时间戳> /etc/sysctl.d/99-bbr-proxy.conf
  sudo sysctl --system
  ```

---

### 5. 生效验证命令
```bash
# 检查当前内核生效参数
sysctl net.ipv4.tcp_congestion_control \
       net.core.default_qdisc \
       net.ipv4.tcp_notsent_lowat \
       net.ipv4.tcp_rmem \
       net.core.rmem_default

# 查看代理端口监听套接字缓冲分配 (rb 数值应与 rmem_default 一致)
ss -tlm 'sport = :<端口号>'

# 产生流量时查看活跃连接的通告窗口 (rcv_wnd 应在 1MB 以上)
ss -ti 'sport = :<端口号>'
```
