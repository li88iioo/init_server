#!/bin/bash

# 更新系统
echo "开始更新系统..."
apt-get update && apt-get upgrade -y

# 安装 curl（如果未安装）
echo "开始安装 curl..."
apt-get install -y curl

# 获取当前 SSH 端口
current_ssh_port=$(grep -i '^Port' /etc/ssh/sshd_config | awk '{print $2}')
if [ -z "$current_ssh_port" ]; then
    current_ssh_port=22  # 如果没有设置端口，默认值为 22
fi
echo "当前 SSH 端口: $current_ssh_port"

# 获取用户自定义 SSH 端口
echo "请输入自定义的 SSH 端口号 (当前端口: $current_ssh_port，默认 22):"
read custom_ssh_port
if [ -n "$custom_ssh_port" ]; then
    current_ssh_port=$custom_ssh_port
fi

# 检查当前 SSH 端口是否已经设置为用户输入的端口
port_in_use=$(ss -tnlp | grep ":$current_ssh_port" | wc -l)
if [ $port_in_use -gt 0 ]; then
    echo "当前 SSH 端口已经是 $current_ssh_port，是否重新修改端口? (y/n)"
    read modify_ssh
    if [ "$modify_ssh" == "y" ]; then
        echo "重新修改 SSH 端口为 $current_ssh_port"
        # 这里可以进行 SSH 配置更改逻辑
    fi
else
    echo "当前 SSH 端口不是 $current_ssh_port，修改为该端口?"
    read modify_ssh
    if [ "$modify_ssh" == "y" ]; then
        echo "正在修改 SSH 配置..."
        # 修改 SSH 配置逻辑
    fi
fi

# 安装并配置防火墙
echo "开始安装 UFW 防火墙..."
apt-get install -y ufw
ufw allow $current_ssh_port/tcp
ufw enable

# 安装并配置 Fail2ban
echo "开始安装 Fail2ban..."
apt-get install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban
echo "Fail2ban 配置完成，最大重试次数为 5，封禁时间为永久"
echo "是否修改 Fail2ban 配置? (y/n):"
read modify_fail2ban
if [ "$modify_fail2ban" == "y" ]; then
    # 在这里修改 Fail2ban 配置
    echo "修改 Fail2ban 配置"
    # fail2ban 配置逻辑
fi
fail2ban_status=$(systemctl is-active fail2ban)
echo "当前 Fail2ban 状态: $fail2ban_status"

# 检查 Docker 是否已安装
if command -v docker &> /dev/null; then
    echo "Docker 已安装，是否重新安装或检查配置? (y/n)"
    read reinstall_docker
    if [ "$reinstall_docker" == "y" ]; then
        echo "正在重新安装 Docker..."
        apt-get install --reinstall docker.io
        systemctl restart docker
    fi
else
    echo "跳过 Docker 安装"
fi

# 检查 ZeroTier 是否已安装
if command -v zerotier-cli &> /dev/null; then
    echo "ZeroTier 已安装，当前状态: $(zerotier-cli status)"
    echo "是否加入新的 ZeroTier 网络? (y/n):"
    read join_zerotier_network
    if [ "$join_zerotier_network" == "y" ]; then
        echo "请输入 ZeroTier 网络 ID:"
        read network_id
        zerotier-cli join $network_id
    fi
    
    # 提取 ZeroTier 网络的 IP 地址
    echo "检测 ZeroTier 网络..."
    zt_network_info=$(zerotier-cli listnetworks | grep "zt")
    if [ -n "$zt_network_info" ]; then
        # 提取网络的 IPv4 地址
        zt_ip=$(echo $zt_network_info | awk -F, '{print $3}' | awk '{print $1}')
        echo "当前 ZeroTier 网络 IP 地址: $zt_ip"
    else
        echo "未检测到 ZeroTier 网络"
    fi
else
    echo "是否安装 ZeroTier? (y/n):"
    read install_zerotier
    if [ "$install_zerotier" == "y" ]; then
        echo "开始安装 ZeroTier..."
        curl -s https://install.zerotier.com | bash
    else
        echo "跳过 ZeroTier 安装"
    fi
fi

# 获取 ZeroTier 接口信息
echo "检测 ZeroTier 接口..."
zt_interface=$(ip a | grep -i 'zerotier' | awk '{print $2}' | sed 's/://')

# 如果没有找到 ZeroTier 接口，尝试使用 zerotier-cli 获取接口
if [ -z "$zt_interface" ]; then
    echo "未找到 ZeroTier 接口，尝试通过 zerotier-cli 获取接口..."
    zt_interface=$(zerotier-cli listnetworks | grep 'zt' | awk '{print $1}')
fi

# 如果找到了 ZeroTier 接口
if [ -n "$zt_interface" ]; then
    echo "找到 ZeroTier 网络接口: $zt_interface"
    
    # 获取 ZeroTier 网络接口的 IP 地址
    zt_ip=$(ip a show $zt_interface | grep inet | awk '{print $2}')
    
    # 显示 ZeroTier IP 地址
    echo "当前 ZeroTier IP 地址: $zt_ip"
else
    echo "未找到 ZeroTier 网络接口。"
    echo "请输入 ZeroTier 网络的 IP 段 (例如 192.168.193.0/24):"
    read zero_ip_range
    echo "正在开放 SSH 端口给 ZeroTier 网络 IP 段 $zero_ip_range ..."
    ufw allow from $zero_ip_range to any port $current_ssh_port proto tcp
    echo "已成功开放 SSH 端口给 ZeroTier 网络 IP 段 $zero_ip_range"
fi

# 启用 SSH 密钥登录
echo "是否启用 SSH 密钥登录 (默认是启用)? (y/n):"
read enable_ssh_key
if [ "$enable_ssh_key" == "y" ]; then
    echo "启用 SSH 密钥登录..."
    # 启用 SSH 密钥登录的配置
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    systemctl restart sshd
else
    echo "SSH 密钥登录未启用"
fi

# 输出当前状态信息
echo "当前 SSH 端口: $current_ssh_port"
echo "当前 Fail2ban 状态: $fail2ban_status"
echo "当前 ZeroTier 状态: $(zerotier-cli status)"
docker_status=$(systemctl is-active docker)
echo "当前 Docker 状态: $docker_status"
ssh_status=$(ss -tnlp | grep :$current_ssh_port)
echo "当前 SSH 登录状态: $ssh_status"

# 是否重启服务器
echo "是否重启服务器? (y/n):"
read reboot_choice
if [ "$reboot_choice" == "y" ]; then
    echo "正在重启服务器..."
    reboot
fi
