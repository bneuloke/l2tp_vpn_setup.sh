#!/bin/bash

# ======================================
# SSTP VPN 一键安装脚本 (Ubuntu)
# 功能:
# - 自动安装依赖
# - 编译 SSTP Server
# - 生成自签名证书
# - 创建用户 user1~user10，密码 password
# - 配置 systemd 开机自启
# - 启动并检测服务
# - 记录日志到 /var/log/sstpd.log
# ======================================

set -e

echo "======================================"
echo "SSTP VPN 一键安装脚本"
echo "======================================"

# -------------------------
# 1. 检测 root 权限
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

# 检查依赖是否已安装
deps=(build-essential libssl-dev libreadline-dev libncurses5-dev libpam0g-dev libpcap-dev git wget curl iptables-persistent)
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
# 9. 检测服务状态
# -------------------------
sleep 3
echo "[*] 检测 SSTP 服务是否监听 TCP 443..."
if netstat -tulnp | grep ':443' &> /dev/null; then
    echo "[✅] SSTP 服务已启动并监听 TCP 443"
else
    echo "[❌] SSTP 服务未成功启动"
    echo "请检查日志: journalctl -u sstpd -f 或 /var/log/sstpd.log"
fi

# -------------------------
# 10. 完成提示
# -------------------------
echo "======================================"
echo "SSTP VPN 安装完成！"
echo "用户: user1~user10"
echo "密码: password"
echo "日志: /var/log/sstpd.log"
echo "请使用 TCP 443 连接 SSTP"
echo "======================================"
