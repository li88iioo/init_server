#!/bin/bash

# 更新系统
echo "开始更新系统..."
apt-get update && apt-get upgrade -y

# 安装 curl（如果未安装）
echo "开始安装 curl..."
apt-get install -y curl

# 获取当前 SSH 端口
echo "检测当前 SSH 端口..."
ssh_port=$(ss -tnlp | grep ':22' | wc -l)
if [ $ssh_port -gt 0 ]; then
    ssh_port=22
else
    ssh_port=12580
fi
echo "当前 SSH 端口: $ssh_port"

# 询问是否自定义 SSH 端口
read -p "请输入自定义的 SSH 端口号 (当前端口: $ssh_port，默认 22): " custom_ssh_port
custom_ssh_port=${custom_ssh_port:-$ssh_port}

if [ "$custom_ssh_port" != "$ssh_port" ]; then
    echo "正在修改 SSH 端口为 $custom_ssh_port"
    # 修改 SSH 配置
    sed -i 's/^#Port 22/Port '$custom_ssh_port'/' /etc/ssh/sshd_config
    systemctl restart sshd
fi

# 检查并修改 Fail2ban 配置，确保其监控新端口
echo "正在更新 Fail2ban 配置..."
fail2ban_config="/etc/fail2ban/jail.local"
if [ ! -f "$fail2ban_config" ]; then
    echo "未找到 $fail2ban_config 文件，创建新的配置文件..."
    touch "$fail2ban_config"
fi

# 更新 Fail2ban 配置中的 SSH 端口
echo "修改 Fail2ban 配置文件 $fail2ban_config，监控端口 $custom_ssh_port..."
sed -i "s/^#port = ssh/port = $custom_ssh_port/" "$fail2ban_config"

# 重启 Fail2ban 服务
systemctl restart fail2ban
echo "Fail2ban 配置已更新，并重启服务应用新设置"

# 安装并配置防火墙
echo "开始安装 UFW 防火墙..."
apt-get install -y ufw
ufw allow $custom_ssh_port/tcp
ufw enable

# 安装并配置 Fail2ban
echo "开始安装 Fail2ban..."
apt-get install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban
echo "Fail2ban 配置完成，最大重试次数为 5，封禁时间为永久"

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

# 检查 ZeroTier 状态
echo "检测 ZeroTier 状态..."
zt_status=$(zerotier-cli status)
echo "当前 ZeroTier 状态: $zt_status"

# 获取 ZeroTier 接口信息
echo "检测 ZeroTier 接口..."
zt_interface=$(ip a | grep -i 'zerotier' | awk '{print $2}' | sed 's/://')

# 如果没有找到 ZeroTier 接口，尝试通过 zerotier-cli 获取接口
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
    ufw allow from $zero_ip_range to any port $custom_ssh_port proto tcp
    echo "已成功开放 SSH 端口给 ZeroTier 网络 IP 段 $zero_ip_range"
fi

# 启用 SSH 密钥登录
echo "是否启用 SSH 密钥登录 (默认是启用)? (y/n):"
read enable_ssh_key
enable_ssh_key=${enable_ssh_key:-y}

if [[ "$enable_ssh_key" == "y" || "$enable_ssh_key" == "Y" ]]; then
    echo "启用 SSH 密钥登录..."
    # 检查用户的公钥是否已上传
    if [ ! -f "$HOME/.ssh/authorized_keys" ]; then
        echo "错误：未找到 SSH 公钥，请确保已上传公钥到 $HOME/.ssh/authorized_keys 文件"
        exit 1
    fi
    # 启用 SSH 密钥登录
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    systemctl restart sshd
else
    echo "SSH 密钥登录未启用"
fi

# 输出当前状态信息
echo "当前 SSH 端口: $custom_ssh_port"
echo "当前 Fail2ban 状态: $(systemctl is-active fail2ban)"
echo "当前 ZeroTier 状态: $(zerotier-cli status)"
docker_status=$(systemctl is-active docker)
echo "当前 Docker 状态: $docker_status"
ssh_status=$(ss -tnlp | grep :$custom_ssh_port)
echo "当前 SSH 登录状态: $ssh_status"

# 是否重启服务器
echo "是否重启服务器? (y/n):"
read reboot_choice
if [ "$reboot_choice" == "y" ]; then
    echo "正在重启服务器..."
    reboot
fi
