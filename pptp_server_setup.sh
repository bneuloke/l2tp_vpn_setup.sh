#!/bin/bash

# 确保脚本以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以 root 权限运行" 
   exit 1
fi

# 检查 PPTP 服务是否已安装，如果未安装则安装
if ! command -v pptpd &> /dev/null
then
    echo "PPTP 服务端未安装，正在安装..."
    apt update
    apt install -y pptpd
else
    echo "PPTP 服务端已安装，跳过安装步骤。"
fi

# ----------------------------------------------------
# 配置文件：/etc/pptpd.conf
# ----------------------------------------------------
echo "正在配置 PPTP..."

cat > /etc/pptpd.conf <<EOF
option /etc/ppp/pptpd-options
logwtmp
localip 192.168.0.1
remoteip 192.168.0.101-110
EOF

# ----------------------------------------------------
# 配置文件：/etc/ppp/pptpd-options
# ----------------------------------------------------
cat > /etc/ppp/pptpd-options <<EOF
name pptpd
refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2
require-mppe-128
ms-dns 8.8.8.8
ms-dns 8.8.4.4
proxyarp
nodefaultroute
lock
nobsdcomp
EOF

# ----------------------------------------------------
# 配置文件：/etc/ppp/chap-secrets
# ----------------------------------------------------
echo "正在添加用户..."
# 清空现有用户
echo "# Secrets for authentication using CHAP" > /etc/ppp/chap-secrets

# 添加 user1 到 user10，密码均为 password
for i in $(seq 1 10)
do
    echo "user$i pptpd password *" >> /etc/ppp/chap-secrets
done

# ----------------------------------------------------
# 开启 IP 转发
# ----------------------------------------------------
echo "正在开启 IP 转发..."
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# ----------------------------------------------------
# 配置 iptables
# ----------------------------------------------------
echo "正在配置 iptables 规则..."
# 获取 VPS 的主网络接口名称
main_interface=$(ip route | grep default | awk '{print $5}' | head -n 1)

# 清除旧规则并设置新规则
iptables -t nat -A POSTROUTING -o $main_interface -j MASQUERADE
iptables-save > /etc/iptables.rules

# ----------------------------------------------------
# 重启服务
# ----------------------------------------------------
echo "正在重启 PPTP 服务..."
systemctl restart pptpd

echo "PPTP 服务端已成功配置！"
echo "用户名：user1 到 user10"
echo "密码：password"
echo "你可以使用你的 VPS IP (18.163.100.160) 进行连接。"
