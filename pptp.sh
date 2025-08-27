#!/bin/bash
# 一键安装配置 PPTP VPN (仅测试用途，Ubuntu 24.04)

set -e

echo "=== 安装依赖 ==="
apt-get update -y
apt-get install -y wget ppp iptables

echo "=== 下载并安装旧版 pptpd 包 ==="
# 选择 Ubuntu 20.04 (focal) 的旧版本 pptpd
TMP_DEB="/tmp/pptpd.deb"
wget -O "$TMP_DEB" http://archive.ubuntu.com/ubuntu/pool/universe/p/pptpd/pptpd_1.4.0-7_amd64.deb
dpkg -i "$TMP_DEB" || apt-get -f install -y

# 检查内核模块
modprobe gre || true
modprobe ppp_mppe || true

echo "=== 配置 pptpd ==="
# 本地 IP 和客户端 IP 池
sed -i '/^localip/d' /etc/pptpd.conf
sed -i '/^remoteip/d' /etc/pptpd.conf
echo "localip 192.168.0.1" >> /etc/pptpd.conf
echo "remoteip 192.168.0.100-200" >> /etc/pptpd.conf

# 配置 DNS
sed -i '/^ms-dns/d' /etc/ppp/pptpd-options
echo "ms-dns 8.8.8.8" >> /etc/ppp/pptpd-options
echo "ms-dns 8.8.4.4" >> /etc/ppp/pptpd-options

# 禁用 MPPE 加密 (风险!)
sed -i '/^require-mppe/d' /etc/ppp/pptpd-options
echo "nomppe" >> /etc/ppp/pptpd-options

# 添加用户 user1-user10, 密码 password
> /etc/ppp/chap-secrets
for i in $(seq 1 10); do
  echo "user$i pptpd password *" >> /etc/ppp/chap-secrets
done

echo "=== 启用内核转发和 NAT ==="
sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf && \
  sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || \
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 获取默认出口网卡
IFACE=$(ip route | grep '^default' | awk '{print $5}')
iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
iptables -A FORWARD -p tcp --syn -s 192.168.0.0/24 -j TCPMSS --clamp-mss-to-pmtu
iptables-save > /etc/iptables.rules

cat >/etc/network/if-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
chmod +x /etc/network/if-up.d/iptables

echo "=== 启动 pptpd 并设置开机自启 ==="
systemctl enable pptpd
systemctl restart pptpd

echo "=== 检查服务状态 ==="
if pgrep pptpd >/dev/null; then
  echo "PPTP 服务已启动"
  echo "用户名: user1 ~ user10, 密码: password"
else
  echo "PPTP 服务启动失败，请检查 /var/log/syslog"
  exit 1
fi
