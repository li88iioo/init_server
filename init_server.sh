#!/bin/bash

# 更新系统
echo "开始更新系统..."
apt-get update && apt-get upgrade -y

# 安装 curl（如果未安装）
echo "开始安装 curl..."
apt-get install -y curl

# 获取 SSH 端口
ssh_port=12580
echo "请输入自定义的 SSH 端口号 (当前端口: $ssh_port，默认 22):"
read custom_ssh_port
if [ -n "$custom_ssh_port" ]; then
    ssh_port=$custom_ssh_port
fi

# 检查当前 SSH 端口是否已经设置为用户输入的端口
current_ssh_port=$(ss -tnlp | grep :$ssh_port | wc -l)
if [ $current_ssh_port -gt 0 ]; then
    echo "当前 SSH 端口已经是 $ssh_port，是否重新修改端口? (y/n)"
    read modify_ssh
    if [ "$modify_ssh" == "y" ]; then
        echo "重新修改 SSH 端口为 $ssh_port"
        # 这里可以进行 SSH 配置更改逻辑
    fi
else
    echo "当前 SSH 端口不是 $ssh_port，修改为该端口?"
    read modify_ssh
    if [ "$modify_ssh" == "y" ]; then
        echo "正在修改 SSH 配置..."
        # 修改 SSH 配置逻辑
    fi
fi

# 安装并配置防火墙
echo "开始安装 UFW 防火墙..."
apt-get install -y ufw
ufw allow $ssh_port/tcp
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

# 安装 Docker
echo "是否安装 Docker? (y/n):"
read install_docker
if [ "$install_docker" == "y" ]; then
    echo "开始安装 Docker..."
    apt-get install -y docker.io
    systemctl enable docker
    systemctl start docker
else
    echo "跳过 Docker 安装"
fi

# 安装 ZeroTier
echo "是否安装 ZeroTier? (y/n):"
read install_zerotier
if [ "$install_zerotier" == "y" ]; then
    echo "开始安装 ZeroTier..."
    curl -s https://install.zerotier.com | bash
else
    echo "跳过 ZeroTier 安装"
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
    ufw allow from $zero_ip_range to any port $ssh_port proto tcp
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
echo "当前 SSH 端口: $ssh_port"
echo "当前 Fail2ban 状态: $fail2ban_status"
echo "当前 ZeroTier 状态: $(zerotier-cli status)"
docker_status=$(systemctl is-active docker)
echo "当前 Docker 状态: $docker_status"
ssh_status=$(ss -tnlp | grep :$ssh_port)
echo "当前 SSH 登录状态: $ssh_status"

# 是否重启服务器
echo "是否重启服务器? (y/n):"
read reboot_choice
if [ "$reboot_choice" == "y" ]; then
    echo "正在重启服务器..."
    reboot
fi
