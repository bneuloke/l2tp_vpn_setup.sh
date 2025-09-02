#!/bin/bash

# 检查是否以root用户运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root用户运行" 1>&2
   exit 1
fi

# 更新系统并安装所需软件包
apt-get update
apt-get install -y xl2tpd ppp

# 配置 xl2tpd
XL2TPD_CONF="/etc/xl2tpd/xl2tpd.conf"
cat > "$XL2TPD_CONF" << EOL
[global]
listen-addr = 0.0.0.0

[lns default]
ip range = 192.168.42.10-192.168.42.254
local ip = 192.168.42.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tp-server
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
EOL

# 配置 ppp 选项
PPP_OPTIONS="/etc/ppp/options.xl2tpd"
cat > "$PPP_OPTIONS" << EOL
ipcp-accept-local
ipcp-accept-remote
ms-dns 8.8.8.8
ms-dns 8.8.4.4
auth
crtscts
idle 1800
mtu 1410
mru 1410
lock
connect-delay 5000
EOL

# 配置用户账户
PPP_SECRETS="/etc/ppp/chap-secrets"
echo "# client server secret IP addresses" > "$PPP_SECRETS"
for i in $(seq 1 10); do
    echo "user$i * password *" >> "$PPP_SECRETS"
done

# 启用内核转发
SYSCTL_CONF="/etc/sysctl.conf"
if ! grep -q "net.ipv4.ip_forward=1" "$SYSCTL_CONF"; then
    echo "net.ipv4.ip_forward=1" >> "$SYSCTL_CONF"
fi
sysctl -p

# 配置防火墙 (iptables)
# L2TP 使用 UDP 端口 1701
iptables -A INPUT -p udp --dport 1701 -j ACCEPT

# 启用 NAT 转发
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i ppp+ -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o ppp+ -j ACCEPT

# 保存 iptables 规则
iptables-save > /etc/iptables/rules.v4

# 重新启动服务
service xl2tpd restart

echo "L2TP 服务器配置完成！"
echo "用户名: user1 到 user10, 密码: password"
echo "由于没有使用 IPsec，部分设备可能需要手动关闭 IPsec 或选择 L2TP (without IPsec) 连接方式。"
