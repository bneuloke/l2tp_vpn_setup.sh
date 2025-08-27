#!/bin/bash
# pptp.sh - 一键安装配置 PPTP VPN 服务端
# 仅用于实验/内网环境，禁用加密存在安全风险！

set -e

echo "=== 更新系统并安装 PPTP 服务 ==="
apt-get update -y
apt-get install -y pptpd net-tools iptables

echo "=== 配置 pptpd ==="
# 配置服务器IP和客户端IP池
sed -i '/^localip/d' /etc/pptpd.conf
sed -i '/^remoteip/d' /etc/pptpd.conf
echo "localip 192.168.0.1" >> /etc/pptpd.conf
echo "remoteip 192.168.0.100-200" >> /etc/pptpd.conf

# 配置DNS
sed -i '/^ms-dns/d' /etc/ppp/pptpd-options
echo "ms-dns 8.8.8.8" >> /etc/ppp/pptpd-options
echo "ms-dns 8.8.4.4" >> /etc/ppp/pptpd-options

# 允许明文（不加密），需谨慎
sed -i '/^require-mppe/d' /etc/ppp/pptpd-options
echo "nomppe" >> /etc/ppp/pptpd-options

echo "=== 添加用户 ==="
> /etc/ppp/chap-secrets
for i in $(seq 1 10); do
  echo "user$i pptpd password *" >> /etc/ppp/chap-secrets
done

echo "=== 配置内核转发和NAT ==="
sysctl -w net.ipv4.ip_forward=1
sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 假设默认网卡为 eth0，如有不同请修改
IFACE=$(ip route | grep '^default' | awk '{print $5}')
iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
iptables -A FORWARD -p tcp --syn -s 192.168.0.0/24 -j TCPMSS --clamp-mss-to-pmtu
iptables-save > /etc/iptables.rules
cat > /etc/network/if-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
chmod +x /etc/network/if-up.d/iptables

echo "=== 启动并设置开机自启 ==="
systemctl enable pptpd
systemctl restart pptpd

echo "=== 检测服务是否运行 ==="
if pgrep pptpd > /dev/null; then
    echo "PPTP 服务已成功启动！"
    echo "用户名: user1-user10 密码: password"
else
    echo "PPTP 服务启动失败，请检查日志 /var/log/syslog"
    exit 1
fi
