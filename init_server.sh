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

# 输出当前状态
echo "当前 SSH 端口: $ssh_port"
echo "当前 Fail2ban 状态: $(systemctl status fail2ban | grep 'Active' | awk '{print $2}')"
echo "当前 ZeroTier 状态: $zerotier_status"
echo "当前 SSH 登录状态: $(ss -tnlp | grep :$ssh_port)"
echo "当前 Docker 状态: $(systemctl is-active docker)"
