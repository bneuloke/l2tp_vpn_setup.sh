#!/bin/bash

# 安装必要的软件包
echo "正在安装必要的软件包..."
sudo apt-get update
sudo apt-get install -y pptpd

# 配置PPTP服务器
echo "正在配置PPTP服务器..."

# 配置PPTP的IP地址
sudo sed -i 's/^#localip 192.168.0.1/localip 192.168.0.1/' /etc/pptpd.conf
sudo sed -i 's/^#remoteip 192.168.0.234-238,192.168.0.245/remoteip 192.168.0.234-238,192.168.0.245/' /etc/pptpd.conf
# 移除已有的remoteip配置并添加新的
sudo sed -i '/remoteip/d' /etc/pptpd.conf
sudo sed -i '/^localip/a remoteip 10.0.0.100-200' /etc/pptpd.conf

# 配置DNS服务器
sudo sed -i 's/^#ms-dns 10.0.0.1/ms-dns 8.8.8.8/' /etc/ppp/options.pptpd
sudo sed -i 's/^#ms-dns 10.0.0.2/ms-dns 8.8.4.4/' /etc/ppp/options.pptpd

# 配置用户账户
echo "正在配置用户账户..."
for i in $(seq 1 10); do
  echo "user$i pptpd password *" | sudo tee -a /etc/ppp/chap-secrets
done

# 启用IPv4转发
echo "正在启用IPv4转发..."
sudo sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sudo sysctl -p

# 配置iptables规则
echo "正在配置iptables规则..."
# 获取VPS的公网IP地址
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)

# 清除所有iptables规则，以防冲突
sudo iptables -F
sudo iptables -X
sudo iptables -Z

# PPTP端口转发
sudo iptables -A INPUT -p tcp --dport 1723 -j ACCEPT
sudo iptables -A INPUT -p gre -j ACCEPT
sudo iptables -A FORWARD -s 10.0.0.0/24 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1356
sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE

# 保存iptables规则
sudo iptables-save | sudo tee /etc/iptables/rules.v4

# 重启PPTPD服务
echo "正在重启PPTP服务..."
sudo systemctl restart pptpd

echo "PPTP服务器安装和配置完成！"
echo "您的公网IP地址是: $PUBLIC_IP"
echo "用户名: user1 到 user10"
echo "密码: password"
