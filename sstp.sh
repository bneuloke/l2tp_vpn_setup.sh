#!/bin/bash

# sstp.sh - 一键安装 SSTP VPN 服务
# 仅适用于 Ubuntu 系统

set -e

echo "检测系统环境..."
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户执行此脚本！"
    exit 1
fi

# 更新系统
apt update -y
apt upgrade -y

# 安装依赖
echo "安装依赖包..."
apt install -y build-essential libssl-dev libreadline-dev libncurses5-dev libpam0g-dev libpcap-dev git wget curl iptables-persistent

# 安装 SSTP Server
echo "下载并编译 SSTP Server..."
cd /usr/local/src
if [ ! -d "sstp-server" ]; then
    git clone https://github.com/enaess/stable-sstp-server.git sstp-server
fi
cd sstp-server
make
make install

# 创建证书
echo "生成自签名证书..."
mkdir -p /etc/ssl/sstp
cd /etc/ssl/sstp
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/C=US/ST=CA/L=SanFrancisco/O=MyVPN/OU=IT/CN=sstp.local" \
    -keyout server.key -out server.crt

# 创建 SSTP 用户
echo "创建用户 user1~user10..."
for i in $(seq 1 10); do
    user="user$i"
    password="password"
    # 使用 SSTP Server 内部用户文件
    echo "$user:$password" >> /etc/ppp/chap-secrets
done

chmod 600 /etc/ppp/chap-secrets

# 配置 SSTP Server
echo "配置 SSTP 服务..."
cat > /etc/sstp-server.conf <<EOF
# SSTP Server 配置
listen_port 443
cert_file /etc/ssl/sstp/server.crt
key_file /etc/ssl/sstp/server.key
EOF

# 配置防火墙
echo "允许 TCP/UDP 所有流量..."
iptables -I INPUT -p tcp --dport 443 -j ACCEPT
iptables -I INPUT -p udp -j ACCEPT
iptables-save > /etc/iptables/rules.v4

# 启动 SSTP 服务
echo "启动 SSTP 服务..."
sstpd -c /etc/sstp-server.conf

echo "=========================================="
echo "SSTP VPN 安装完成！"
echo "用户: user1~user10"
echo "密码: password"
echo "请确保客户端使用 TCP 443 连接"
echo "=========================================="
