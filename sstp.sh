#!/bin/bash
# sstp_auto.sh - 一键安装 SoftEther VPN Server (SSTP) 并添加用户
# 自动检测依赖，已安装则跳过

set -e

echo "=== 检查并安装依赖 ==="
DEPENDENCIES=(build-essential gcc make libreadline-dev libssl-dev zlib1g-dev libncurses5-dev wget curl iptables)

for pkg in "${DEPENDENCIES[@]}"; do
    if dpkg -s "$pkg" &>/dev/null; then
        echo "依赖 $pkg 已安装，跳过"
    else
        echo "依赖 $pkg 未安装，正在安装..."
        apt-get update -y
        apt-get install -y "$pkg"
    fi
done

echo "=== 下载 SoftEther VPN Server ==="
TMP_DIR="/tmp/softether"
mkdir -p $TMP_DIR
cd $TMP_DIR

if [ ! -f vpnserver.tar.gz ]; then
    wget -O vpnserver.tar.gz https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v4.60-9760-beta/softether-vpnserver-v4.60-9760-beta-2023.06.28-linux-x64-64bit.tar.gz
else
    echo "已存在下载文件，跳过"
fi

if [ ! -d vpnserver ]; then
    tar xzf vpnserver.tar.gz
else
    echo "已存在解压目录，跳过"
fi

echo "=== 编译 SoftEther VPN Server ==="
cd vpnserver
if [ ! -f vpnserver/vpnserver ]; then
    yes 1 | make
else
    echo "vpnserver 已编译，跳过"
fi

echo "=== 安装并设置开机自启 ==="
cd ..
if [ ! -d /usr/local/vpnserver ]; then
    mv vpnserver /usr/local/
fi

chmod 600 /usr/local/vpnserver/*
chmod 700 /usr/local/vpnserver/vpnserver
chmod 700 /usr/local/vpnserver/vpncmd

cat >/etc/systemd/system/vpnserver.service <<EOF
[Unit]
Description=SoftEther VPN Server
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/vpnserver/vpnserver start
ExecStop=/usr/local/vpnserver/vpnserver stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vpnserver
systemctl start vpnserver

echo "=== 配置 SSTP 用户 ==="
VPNCMD="/usr/local/vpnserver/vpncmd /SERVER localhost /ADMINHUB:DEFAULT /CMD"

# 设置管理员密码
$VPNCMD "ServerPasswordSet password"

# 创建用户 user1~user10
for i in $(seq 1 10); do
    $VPNCMD "UserCreate user$i /GROUP:none /REALNAME:none /NOTE:none" || echo "用户 user$i 已存在，跳过"
    $VPNCMD "UserPasswordSet user$i /PASSWORD:password"
done

echo "=== 配置 NAT ==="
IFACE=$(ip route | grep '^default' | awk '{print $5}')
iptables -t nat -C POSTROUTING -o $IFACE -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
iptables -C FORWARD -s 192.168.30.0/24 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -s 192.168.30.0/24 -j ACCEPT

iptables-save > /etc/iptables.rules

cat >/etc/network/if-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
chmod +x /etc/network/if-up.d/iptables

echo "=== 安装完成 ==="
echo "SSTP VPN 已启动，用户 user1~user10, 密码 password"
echo "请在客户端选择 SSTP 协议，服务器地址使用 VPS 公网 IP"
