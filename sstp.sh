#!/bin/bash

# ======================================
# 完整版 SSTP VPN 一键安装脚本 (Ubuntu)
# 增强功能：
# - 自动安装依赖
# - 生成自签名证书
# - 创建用户 user1~user10，密码 password
# - 配置 systemd 开机自启
# - 配置防火墙
# - 启动服务
# - 自动检测 TCP 443 监听状态
# - 自动检测公网 IP
# - 输出最终连接信息
# - 解决卡屏问题（超时检测）
# ======================================

set -e

echo "======================================"
echo "SSTP VPN 一键安装脚本"
echo "======================================"

# -------------------------
# 1. 检查 root 权限
# -------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行此脚本！"
    exit 1
fi

# -------------------------
# 2. 更新系统并安装依赖
# -------------------------
echo "[*] 更新系统并安装依赖..."
apt update -y
apt upgrade -y

deps=(build-essential libssl-dev libreadline-dev libncurses-dev libpam0g-dev libpcap-dev git wget curl iptables-persistent netcat)
for pkg in "${deps[@]}"; do
    if ! dpkg -s $pkg &> /dev/null; then
        echo "[*] 安装依赖: $pkg"
        apt install -y $pkg
    else
        echo "[*] 已安装: $pkg"
    fi
done

# -------------------------
# 3. 下载并编译 SSTP Server
# -------------------------
echo "[*] 下载并编译 SSTP Server..."
cd /usr/local/src
if [ ! -d "stable-sstp-server" ]; then
    git clone https://github.com/enaess/stable-sstp-server.git
fi
cd stable-sstp-server

echo "[*] 开始编译..."
if make && make install; then
    echo "[✅] SSTP Server 编译安装完成"
else
    echo "[❌] 编译失败，请检查依赖和系统环境"
    exit 1
fi

# -------------------------
# 4. 生成自签名证书
# -------------------------
echo "[*] 生成自签名证书..."
mkdir -p /etc/ssl/sstp
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/C=US/ST=CA/L=SanFrancisco/O=MyVPN/OU=IT/CN=sstp.local" \
    -keyout /etc/ssl/sstp/server.key -out /etc/ssl/sstp/server.crt
chmod 600 /etc/ssl/sstp/server.key /etc/ssl/sstp/server.crt
echo "[✅] 证书生成完成: /etc/ssl/sstp/server.crt"

# -------------------------
# 5. 创建 SSTP 用户
# -------------------------
echo "[*] 创建用户 user1~user10..."
mkdir -p /etc/ppp
touch /etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets

for i in $(seq 1 10); do
    user="user$i"
    password="password"
    grep -q "^$user" /etc/ppp/chap-secrets || echo "$user    *    $password    *" >> /etc/ppp/chap-secrets
done
echo "[✅] 用户创建完成"

# -------------------------
# 6. 创建 SSTP 配置文件
# -------------------------
echo "[*] 配置 SSTP Server..."
mkdir -p /etc/sstp
cat > /etc/sstp-server.conf <<EOF
listen_port 443
cert_file /etc/ssl/sstp/server.crt
key_file /etc/ssl/sstp/server.key
EOF
echo "[✅] 配置文件创建完成: /etc/sstp-server.conf"

# -------------------------
# 7. 创建 systemd 服务
# -------------------------
echo "[*] 创建 systemd 服务..."
cat > /etc/systemd/system/sstpd.service <<EOF
[Unit]
Description=SSTP VPN Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/sstpd -c /etc/sstp-server.conf
Restart=on-failure
StandardOutput=append:/var/log/sstpd.log
StandardError=append:/var/log/sstpd.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sstpd
systemctl start sstpd

# -------------------------
# 8. 配置防火墙
# -------------------------
echo "[*] 配置防火墙..."
iptables -I INPUT -p tcp --dport 443 -j ACCEPT
iptables -I INPUT -p udp -j ACCEPT
iptables-save > /etc/iptables/rules.v4
echo "[✅] 防火墙配置完成"

# -------------------------
# 9. 自动检测服务可用性（加超时避免卡屏）
# -------------------------
sleep 3
echo "[*] 检测 SSTP 服务状态..."

can_connect=0

# 检查 sstpd 进程
if pgrep sstpd &> /dev/null; then
    echo "[✅] SSTP 服务进程运行中"
else
    echo "[❌] SSTP 服务未运行"
fi

# 检查端口监听
if ss -tulnp | grep ':443' &> /dev/null; then
    echo "[✅] TCP 443 正在监听"
    # 使用超时方式检测本地 TCP 连接
    if timeout 5 nc -z 127.0.0.1 443 &> /dev/null; then
        echo "[✅] 本地 TCP 连接测试成功，可以直接连接客户端"
        can_connect=1
    else
        echo "[⚠️] 本地 TCP 连接失败，可能防火墙或服务异常"
    fi
else
    echo "[❌] TCP 443 未监听，客户端无法连接"
fi

# -------------------------
# 10. 检测公网 IP（加超时避免卡屏）
# -------------------------
echo "[*] 检测公网 IP..."
public_ip=$(curl -s --max-time 5 https://ipinfo.io/ip || curl -s --max-time 5 https://ifconfig.me || echo "无法获取公网 IP")
if [ "$public_ip" = "" ]; then
    public_ip="无法获取公网 IP"
fi

# -------------------------
# 11. 输出最终信息
# -------------------------
echo "======================================"
echo "SSTP VPN 安装完成！"
echo "1. 你的公网 IP: $public_ip"
echo "2. 用户名: user1~user10"
echo "3. 密码: password"

if [ $can_connect -eq 1 ]; then
    echo "[✅] 服务可以直接连接，客户端可立即使用"
else
    echo "[⚠️] 服务未完全可用，请检查日志: /var/log/sstpd.log 或 journalctl -u sstpd -f"
fi

echo "TCP 端口: 443"
echo "======================================"
