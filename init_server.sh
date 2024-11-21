#!/bin/bash

# 更新系统
echo "开始更新系统..."
apt update && apt upgrade -y

# 安装 curl
echo "开始安装 curl..."
apt install curl -y

# 获取当前的 SSH 端口
current_ssh_port=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')

# 输入自定义的 SSH 端口号
read -p "请输入自定义的 SSH 端口号 (当前端口: $current_ssh_port，默认 22): " ssh_port
ssh_port=${ssh_port:-22}

# 如果输入的端口号与当前端口号相同，则询问是否修改
if [ "$ssh_port" == "$current_ssh_port" ]; then
    read -p "当前 SSH 端口已经是 $ssh_port，是否重新修改端口? (y/n): " modify_ssh
    if [[ "$modify_ssh" == "y" || "$modify_ssh" == "Y" ]]; then
        echo "修改 SSH 配置文件，将端口号改为 $ssh_port"
        sed -i "s/^Port $current_ssh_port/Port $ssh_port/" /etc/ssh/sshd_config
        systemctl restart sshd
        echo "SSH 端口已修改为 $ssh_port"
    else
        echo "跳过 SSH 端口修改"
    fi
else
    # 如果输入的端口号与当前端口号不同，直接修改
    echo "修改 SSH 配置文件，将端口号改为 $ssh_port"
    sed -i "s/^#Port 22/Port $ssh_port/" /etc/ssh/sshd_config
    systemctl restart sshd
    echo "SSH 端口已修改为 $ssh_port"
fi

# 安装 UFW 并开放 SSH 端口
echo "开始安装 UFW 防火墙..."
apt install ufw -y
ufw allow $ssh_port/tcp
ufw enable

# 安装 Fail2ban 并配置
echo "开始安装 Fail2ban..."
apt install fail2ban -y

# 检测 Fail2ban 配置
fail2ban_status=$(systemctl is-active fail2ban)
if [ "$fail2ban_status" == "active" ]; then
    echo "当前 Fail2ban 已安装并启用，状态: $fail2ban_status"
    read -p "是否修改 Fail2ban 配置? (y/n): " modify_fail2ban
    if [[ "$modify_fail2ban" == "y" || "$modify_fail2ban" == "Y" ]]; then
        cat <<EOL > /etc/fail2ban/jail.d/ssh-$ssh_port.conf
[sshd]
enabled = true
port    = $ssh_port
logpath = /var/log/auth.log
maxretry = 5
bantime  = -1
EOL
        systemctl restart fail2ban
        echo "Fail2ban 配置已更新"
    else
        echo "跳过 Fail2ban 配置修改"
    fi
else
    echo "Fail2ban 没有安装或未启用，正在安装并配置..."
    cat <<EOL > /etc/fail2ban/jail.d/ssh-$ssh_port.conf
[sshd]
enabled = true
port    = $ssh_port
logpath = /var/log/auth.log
maxretry = 5
bantime  = -1
EOL
    systemctl restart fail2ban
    echo "Fail2ban 配置完成，最大重试次数为 5，封禁时间为永久"
fi

# 是否安装 Docker
read -p "是否安装 Docker? (y/n): " install_docker
if [[ "$install_docker" == "y" || "$install_docker" == "Y" ]]; then
    echo "开始安装 Docker..."
    bash <(curl -sSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/DockerInstallation.sh)

    # 检查 Docker 状态
    docker_status=$(systemctl is-active docker)
    if [[ "$docker_status" == "active" ]]; then
        echo "Docker 已安装并启动，当前状态: $docker_status"
        read -p "是否重新配置 Docker? (y/n): " modify_docker
        if [[ "$modify_docker" == "y" || "$modify_docker" == "Y" ]]; then
            echo "正在重新配置 Docker..."
            # 这里可以添加您希望重新配置 Docker 的步骤
        else
            echo "跳过 Docker 配置修改"
        fi
    else
        echo "Docker 未启动，正在启动 Docker..."
        systemctl start docker
    fi
fi

# 是否安装 ZeroTier
read -p "是否安装 ZeroTier? (y/n): " install_zerotier
if [[ "$install_zerotier" == "y" || "$install_zerotier" == "Y" ]]; then
    echo "开始安装 ZeroTier..."
    curl -s https://install.zerotier.com | sudo bash

    # 检查 ZeroTier 状态
    zerotier_status=$(sudo zerotier-cli status)
    if [[ "$zerotier_status" == *"OK"* ]]; then
        echo "ZeroTier 已经加入网络，当前状态：$zerotier_status"
        read -p "是否加入新的 ZeroTier 网络? (y/n): " join_new_network
        if [[ "$join_new_network" == "y" || "$join_new_network" == "Y" ]]; then
            read -p "请输入 ZeroTier 网络密钥: " zerotier_network_id
            sudo zerotier-cli join $zerotier_network_id
        else
            echo "跳过加入新网络"
        fi
    else
        read -p "请输入 ZeroTier 网络密钥: " zerotier_network_id
        sudo zerotier-cli join $zerotier_network_id
    fi

    # 等待并验证是否加入 ZeroTier 网络
    echo "正在等待 ZeroTier 加入网络..."
    sleep 5  # 等待 5 秒
    zerotier_status=$(sudo zerotier-cli status)
    if [[ "$zerotier_status" == *"OK"* ]]; then
        echo "ZeroTier 已成功加入网络 $zerotier_network_id"
    else
        echo "错误：ZeroTier 加入网络失败，请检查网络密钥。继续执行脚本..."
    fi

    # 获取 ZeroTier 网络分配的 IP 地址
    zerotier_ip=$(sudo zerotier-cli listnetworks | grep $zerotier_network_id | awk '{print $4}')
    if [ -z "$zerotier_ip" ]; then
        echo "错误：未能获取 ZeroTier IP 地址。"
    else
        echo "ZeroTier 网络 IP 地址: $zerotier_ip"
    fi

    # 提示用户输入 ZeroTier IP 段
    read -p "请输入 ZeroTier 网络的 IP 段 (例如 192.168.192.0/24): " zerotier_ip_range

    # 开放 SSH 端口给 ZeroTier 网络 IP 段
    echo "正在开放 SSH 端口给 ZeroTier 网络 IP 段 $zerotier_ip_range ..."
    sudo ufw allow from $zerotier_ip_range to any port $ssh_port proto tcp
    sudo systemctl restart ufw
    echo "已成功开放 SSH 端口给 ZeroTier 网络 IP 段 $zerotier_ip_range"
fi

# 是否开启 SSH 密钥登录
read -p "是否启用 SSH 密钥登录 (默认是启用)? (y/n): " enable_ssh_key
enable_ssh_key=${enable_ssh_key:-y}
if [[ "$enable_ssh_key" == "y" || "$enable_ssh_key" == "Y" ]]; then
    echo "启用 SSH 密钥登录..."
    # 检查用户的公钥是否已上传
    if [ ! -f "$HOME/.ssh/authorized_keys" ]; then
        echo "错误：未找到 SSH 公钥，请确保已上传公钥到 $HOME/.ssh/authorized_keys 文件"
        exit 1
    fi

    # 禁用密码认证，启用密钥认证
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#ChallengeResponseAuthentication yes/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    systemctl restart sshd
    echo "已禁用密码认证，仅允许 SSH 密钥认证登录。"
fi

# 输出当前状态
echo "当前 SSH 端口: $ssh_port"
echo "当前 Fail2ban 状态: $(systemctl status fail2ban | grep 'Active' | awk '{print $2}')"
echo "当前 ZeroTier 状态: $(sudo zerotier-cli status)"
echo "当前 Docker 状态: $(systemctl is-active docker)"
echo "当前 SSH 登录状态: $(ss -tnlp | grep :$ssh_port)"


# 是否重启服务器
read -p "是否重启服务器? (y/n): " reboot_server
if [[ "$reboot_server" == "y" || "$reboot_server" == "Y" ]]; then
    echo "正在重启服务器..."
    reboot
else
    echo "初始化完成，无需重启"
fi

