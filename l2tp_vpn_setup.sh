#!/bin/bash

# 安装 pptpd
apt update && apt install -y pptpd

# 配置 pptpd 监听
cat > /etc/pptpd.conf <<EOF
option /etc/ppp/pptpd-options
logwtmp
localip 192.168.0.1
remoteip 192.168.0.100-200
EOF

# 配置 PPP 选项
cat > /etc/ppp/pptpd-options <<EOF
name pptpd
refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2
require-mppe-128
ms-dns 8.8.8.8
ms-dns 1.1.1.1
proxyarp
lock
nobsdcomp
novj
novjccomp
nologfd
EOF

# 添加用户
> /etc/ppp/chap-secrets
for i in {1..10}; do
    echo "user$i pptpd password *" >> /etc/ppp/chap-secrets
done

# 开启 IP 转发
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

# 配置 NAT 转发
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables-save > /etc/iptables.rules

# 确保开机加载 NAT
cat > /etc/network/if-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
chmod +x /etc/network/if-up.d/iptables

# 启动 pptpd
systemctl enable pptpd
systemctl restart pptpd

echo "PPTP VPN 安装完成。用户: user1-user10, 密码: password"
