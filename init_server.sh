#!/bin/bash

# 更新系统
echo "开始更新系统..."
apt update && apt upgrade -y

# 安装 curl
echo "开始安装 curl..."
apt install curl -y

# 检查并修改默认 SSH 端口
current_ssh_port=$(grep '^Port' /etc/ssh/sshd_config | awk '{print $2}')
if [ -z "$current_ssh_port" ] || [ "$current_ssh_port" == "22" ]; then
    read -p "请输入自定义的 SSH 端口号 (默认 22): " ssh_port
    ssh_port=${ssh_port:-22}
    echo "修改 SSH 配置文件，将端口号改为 $ssh_port"
    sed -i "s/^#Port 22/Port $ssh_port/" /etc/ssh/sshd_config
    systemctl restart sshd
    echo "SSH 端口已修改为 $ssh_port"
else
    echo "当前 SSH 端口已经是 $current_ssh_port，跳过修改。"
fi

# 安装 UFW 并开放 SSH 端口
echo "开始安装 UFW 防火墙..."
apt install ufw -y
ufw allow $ssh_port/tcp
ufw enable

# 检查并安装 Fail2ban
fail2ban_config_file="/etc/fail2ban/jail.d/ssh-$ssh_port.conf"
if [ ! -f "$fail2ban_config_file" ]; then
    echo "开始安装 Fail2ban..."
    apt install fail2ban -y
    cat <<EOL > $fail2ban_config_file
[sshd]
enabled = true
port    = $ssh_port
logpath = /var/log/auth.log
maxretry = 5
bantime  = -1
EOL
    systemctl restart fail2ban
    echo "Fail2ban 配置完成，最大重试次数为 5，封禁时间为永久"
else
    echo "Fail2ban 已经配置了 SSH 端口 $ssh_port，跳过重新配置。"
fi

# 是否安装 Docker
read -p "是否安装 Docker? (y/n): " install_docker
if [[ "$install_docker" == "y" || "$install_docker" == "Y" ]]; then
    echo "开始安装 Docker..."
    bash <(curl -sSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/DockerInstallation.sh)

    # Docker 安装成功后，是否修改 UFW 配置
    read -p "Docker 安装成功后，是否写入 UFW Docker 规则? (y/n): " ufw_docker
    if [[ "$ufw_docker" == "y" || "$ufw_docker" == "Y" ]]; then
        echo "正在写入 Docker 规则到 UFW..."
        echo "# BEGIN UFW AND DOCKER" >> /etc/ufw/after.rules
        cat <<EOL >> /etc/ufw/after.rules
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16
-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 172.16.0.0/12
-A DOCKER-USER -j RETURN
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP
COMMIT
# END UFW AND DOCKER
EOL
        systemctl restart ufw
        echo "UFW Docker 规则已写入并重启"
    fi
fi

# 是否安装 Docker Compose
read -p "是否安装 Docker Compose? (y/n): " install_compose
if [[ "$install_compose" == "y" || "$install_compose" == "Y" ]]; then
    echo "开始安装 Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    echo "Docker Compose 安装完成"
fi

# 是否安装 ZeroTier
read -p "是否安装 ZeroTier? (y/n): " install_zerotier
if [[ "$install_zerotier" == "y" || "$install_zerotier" == "Y" ]]; then
    echo "开始安装 ZeroTier..."
    curl -s https://install.zerotier.com | sudo bash

    # 检查 ZeroTier 是否已经加入网络
    zerotier_networks=$(sudo zerotier-cli listnetworks)

    if [[ -n "$zerotier_networks" ]]; then
        echo "当前系统已经加入以下 ZeroTier 网络："
        echo "$zerotier_networks"
        read -p "是否加入一个新的 ZeroTier 网络? (y/n): " join_new_network
        if [[ "$join_new_network" != "y" && "$join_new_network" != "Y" ]]; then
            echo "跳过加入新网络，继续执行其他步骤..."
            exit 0
        fi
    fi

    # 输入 ZeroTier 网络密钥
    read -p "请输入 ZeroTier 网络密钥: " zerotier_network_id
    sudo zerotier-cli join $zerotier_network_id

    # 重试机制：最大尝试次数
    MAX_RETRIES=5
    RETRY_INTERVAL=30  # 每次重试的间隔时间为 30 秒
    RETRIES=0

    while [ $RETRIES -lt $MAX_RETRIES ]; do
        echo "正在尝试加入 ZeroTier 网络... (尝试次数: $((RETRIES + 1))/$MAX_RETRIES)"
        sudo zerotier-cli join $zerotier_network_id

        # 检查是否成功加入网络
        zerotier_status=$(sudo zerotier-cli status)
        
        # 判断 ZeroTier 状态中是否包含 "OK" 字符串
        if [[ "$zerotier_status" == *"OK"* ]]; then
            echo "ZeroTier 已成功加入网络 $zerotier_network_id"
            break
        else
            echo "ZeroTier 加入网络失败，正在重试..."
            RETRIES=$((RETRIES + 1))
            if [ $RETRIES -ge $MAX_RETRIES ]; then
                echo "加入网络失败，已达到最大重试次数。"
                exit 1
            fi
            sleep $RETRY_INTERVAL
        fi
    done

    # 获取 ZeroTier 网络分配的 IP 地址
    zerotier_ip=$(sudo zerotier-cli listnetworks | grep $zerotier_network_id | awk '{print $4}')
    if [ -z "$zerotier_ip" ]; then
        echo "错误：未能自动获取 ZeroTier IP 地址。"
        # 如果没有自动获取 IP 地址，要求用户手动输入
        read -p "请输入 ZeroTier 网络分配的 IP 地址: " zerotier_ip
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

# 是否重启服务器
read -p "是否重启服务器? (y/n): " reboot_server
if [[ "$reboot_server" == "y" || "$reboot_server" == "Y" ]]; then
    echo "正在重启服务器..."
    reboot
else
    echo "初始化完成，无需重启"
fi

echo "所有操作已完成"
