#!/bin/bash
# L2TP/IPsec VPN 一键安装脚本，支持 IPv4/IPv6，NAT-T 兼容，WinXP-Win10 通用
# PSK: 111111  用户: user1~user10  密码: password

set -e

if [ "$(id -u)" != "0" ]; then
  echo "请使用 root 权限运行"
  exit 1
fi

# 安装依赖
echo "--- 正在安装依赖..."
apt update
apt install -y strongswan xl2tpd ppp lsof iptables-persistent curl

# 获取公网IP
echo "--- 正在获取公网IP..."
PUBLIC_IP=$(curl -s ifconfig.me)

# 配置 strongSwan (IPsec)
echo "--- 正在配置 strongSwan (IPsec)..."
cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids=never
    charondebug="ike 1, knl 1, cfg 0"

conn L2TP-PSK
    authby=secret
    auto=add
    keyexchange=ikev1
    ike=aes256-sha1-modp1024!
    esp=aes256-sha1!
    type=transport
    left=%any
    leftid=$PUBLIC_IP
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
EOF

cat > /etc/ipsec.secrets <<EOF
: PSK "111111"
EOF

# 配置 xl2tpd
echo "--- 正在配置 xl2tpd..."
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lns default]
ip range = 192.168.18.10-192.168.18.250
local ip = 192.168.18.1
require chap = yes
refuse pap = yes
require authentication = yes
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# PPP 配置
echo "--- 正在配置 PPP..."
cat > /etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 2001:4860:4860::8888
asyncmap 0
auth
crtscts
lock
hide-password
modem
debug
name l2tpd
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
mtu 1400
mru 1400
connect-delay 5000
EOF

# 添加10个用户
echo "--- 正在添加 VPN 用户..."
> /etc/ppp/chap-secrets
for i in {1..10}; do
  echo "user$i  l2tpd  password  *" >> /etc/ppp/chap-secrets
done

# 开启IP转发 (IPv4+IPv6)
echo "--- 正在开启 IP 转发..."
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p

# NAT 转换
echo "--- 正在配置 NAT 转换..."
ETH=$(ip route | grep '^default' | awk '{print $5}')
iptables -t nat -A POSTROUTING -o $ETH -j MASQUERADE
ip6tables -t nat -A POSTROUTING -o $ETH -j MASQUERADE
netfilter-persistent save

# 开放端口
echo "--- 正在配置防火墙规则..."
iptables -A INPUT -p udp --dport 500 -j ACCEPT
iptables -A INPUT -p udp --dport 4500 -j ACCEPT
iptables -A INPUT -p udp --dport 1701 -j ACCEPT
iptables -A INPUT -p udp --dport 4500 -m policy --dir in --pol ipsec -j ACCEPT
netfilter-persistent save

# 启动服务 (添加兼容性检查)
echo "--- 正在启动服务..."
# 检查 strongswan 服务名称，兼容不同版本
if systemctl list-units --type=service | grep -q strongswan; then
    SERVICE_NAME="strongswan"
elif systemctl list-units --type=service | grep -q ipsec; then
    SERVICE_NAME="ipsec"
else
    echo "错误：未找到 strongswan 或 ipsec 服务。请检查 strongswan 软件包是否已成功安装。"
    exit 1
fi

systemctl enable $SERVICE_NAME --now
systemctl enable xl2tpd --now

# NAT-T 兼容性提示 (Windows XP-10)
echo "--- NAT-T 兼容性提示：如果 Windows XP/7 出现 809 错误，请在客户端注册表添加 AssumeUDPEncapsulationContextOnSendRule=2"

echo "====================================="
echo "VPN 部署完成!"
echo "服务器IP: $PUBLIC_IP"
echo "PSK: 111111"
echo "用户名: user1 ~ user10"
echo "密码: password"
echo "====================================="
