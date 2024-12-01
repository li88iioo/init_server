#!/bin/bash

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# 错误处理函数
error_exit() {
    echo -e "${RED}错误: $1${NC}"
    exit 1
}

# 成功提示函数
success_msg() {
    echo -e "${GREEN}成功: $1${NC}"
}

# 检查程序是否安装
check_installed() {
    local service_name=$1
    
    # 首先检查命令是否存在
    if ! command -v "$service_name" &> /dev/null; then
        echo -e "${RED}错误: $service_name 未安装${NC}"
        return 1
    fi
    
    # 对于 ZeroTier，使用特定的状态检查方法
    if [ "$service_name" == "zerotier-cli" ]; then
        # 检查 ZeroTier 服务状态
        local zerotier_status=$(systemctl is-active zerotier-one 2>/dev/null)
        if [ "$zerotier_status" != "active" ]; then
            echo -e "${YELLOW}警告: ZeroTier 服务未运行${NC}"
            return 1
        fi
        
        # 额外检查 ZeroTier 网络连接状态
        local cli_status=$(zerotier-cli status 2>/dev/null | grep -c "ONLINE")
        if [ "$cli_status" -eq 0 ]; then
            echo -e "${YELLOW}警告: ZeroTier 未连接${NC}"
            return 1
        fi
    else
        # 对于其他服务，使用原有的检查方法
        if ! systemctl is-active --quiet "$service_name"; then
            echo -e "${YELLOW}警告: $service_name 服务未运行${NC}"
            return 1
        fi
    fi
    
    return 0
}

# 分隔线
show_separator() {
    echo -e "${BLUE}------------------------------------${NC}"
}

# 1. 系统更新和curl安装
system_update() {
    echo "正在更新系统..."
    apt update && apt upgrade -y || error_exit "系统更新失败"
    apt install curl -y || error_exit "curl安装失败"
    success_msg "系统更新完成，curl已安装"
}

# 2. SSH端口相关函数
modify_ssh_port() {
    read -p "请输入新的SSH端口号(1-65535): " new_port
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        error_exit "无效的端口号"
    fi
    
    sed -i "s/#Port 22/Port $new_port/" /etc/ssh/sshd_config
    sed -i "s/Port [0-9]*/Port $new_port/" /etc/ssh/sshd_config
    systemctl restart sshd || error_exit "SSH重启失败"
    success_msg "SSH端口已修改为: $new_port"
}

check_ssh_port() {
    current_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
    echo "当前SSH端口: ${current_port:-22}"
}

# SSH密钥认证配置
configure_ssh_key() {
    if [ ! -f ~/.ssh/authorized_keys ]; then
        echo "未找到authorized_keys文件"
        read -p "是否现在配置SSH密钥?！！！请提前上传密钥以免麻烦 (y/n): " answer
        if [ "$answer" = "y" ]; then
            mkdir -p ~/.ssh
            chmod 700 ~/.ssh
            touch ~/.ssh/authorized_keys
            chmod 600 ~/.ssh/authorized_keys
            
            echo "请选择密钥配置方式:"
            echo "1. 手动复制密钥"
            echo "2. 输入密钥内容"
            read -p "请选择 (1/2): " key_choice
            
            case $key_choice in
                1)
                    echo "请将您的公钥复制到 ~/.ssh/authorized_keys 文件中"
                    ;;
                2)
                    echo "请输入您的公钥内容:"
                    read -r pubkey
                    echo "$pubkey" >> ~/.ssh/authorized_keys
                    if [ $? -eq 0 ]; then
                        success_msg "密钥已添加成功"
                    else
                        error_exit "密钥添加失败"
                    fi
                    ;;
                *)
                    echo "无效的选择"
                    ;;
            esac
        fi
    else
        read -p "是否禁用密码登录? (y/n): " answer
        if [ "$answer" = "y" ]; then
            sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
            sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
            systemctl restart sshd
            success_msg "已开启仅SSH密钥认证登录"
        fi
    fi
}

# 3. UFW防火墙配置
install_ufw() {
    apt install ufw -y || error_exit "UFW安装失败"
    systemctl enable ufw
    systemctl start ufw
    success_msg "UFW已安装并启动"
}

configure_ufw() {
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}请先安装UFW${NC}"
        return 1
    fi
    
    current_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
    ufw allow ${current_port:-22}/tcp || error_exit "UFW配置SSH端口失败"
    ufw enable || error_exit "UFW启动失败"
    success_msg "UFW已启用并开放SSH端口"
}

configure_ufw_ping() {
    echo "PING规则管理:"
    echo "1. 禁止PING"
    echo "2. 恢复PING"
    echo "0. 返回"
    
    read -p "请选择操作: " ping_choice
    
    case $ping_choice in
        1)
            # 使用sysctl禁止PING
            echo 1 | sudo tee /proc/sys/net/ipv4/icmp_echo_ignore_all > /dev/null
            
            # 永久生效
            if ! grep -q "net.ipv4.icmp_echo_ignore_all = 1" /etc/sysctl.conf; then
                echo "net.ipv4.icmp_echo_ignore_all = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
            fi
            
            # 应用更改
            sudo sysctl -p > /dev/null
            
            success_msg "已禁止PING"
            ;;
        
        2)
            # 使用sysctl恢复PING
            echo 0 | sudo tee /proc/sys/net/ipv4/icmp_echo_ignore_all > /dev/null
            
            # 修改sysctl.conf中的配置
            sudo sed -i 's/net.ipv4.icmp_echo_ignore_all = 1/net.ipv4.icmp_echo_ignore_all = 0/' /etc/sysctl.conf
            
            # 应用更改
            sudo sysctl -p > /dev/null
            
            success_msg "已恢复PING"
            ;;
        
        0)
            return 0
            ;;
        
        *)
            echo -e "${RED}无效的选择${NC}"
            return 1
            ;;
    esac
}

check_ufw_status() {
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}请先安装UFW${NC}"
        return 1
    fi
    
    echo "UFW状态:"
    ufw status verbose
}

# 检查Fail2ban服务状态
is_fail2ban_installed() {
    if ! command -v fail2ban-client &> /dev/null; then
        return 1
    fi
    return 0
}

# 4. Fail2ban配置
install_fail2ban() {
    # 检查是否安装了 lsb-release，如果没有，尝试安装它
    if ! command -v lsb_release &> /dev/null; then
        echo "检测到 lsb_release 未安装，尝试安装 lsb-release 包..."
        apt-get install lsb-release -y || error_exit "安装 lsb-release 失败"
    fi

    # 获取系统版本
    debian_version=$(lsb_release -r | awk '{print $2}')
    
    # 如果 lsb_release 失败，尝试从 /etc/os-release 中获取版本
    if [ -z "$debian_version" ]; then
        echo "无法通过 lsb_release 获取版本，尝试从 /etc/os-release 获取..."
        debian_version=$(grep "VERSION_ID" /etc/os-release | cut -d '"' -f 2)
    fi
    
    # 如果是 Debian 12 或更高版本，安装 rsyslog
    if [ "$(echo $debian_version | cut -d'.' -f1)" -ge 12 ]; then
        echo "检测到 Debian 12 或更高版本，安装 rsyslog..."
        apt-get install rsyslog -y || error_exit "rsyslog 安装失败"
        
        # 启动并启用 rsyslog 服务
        systemctl enable rsyslog
        systemctl start rsyslog
        
        echo "rsyslog 已安装并启动"
    else
        echo "当前不是 Debian 12 或更高版本，无需安装 rsyslog"
    fi

    # 安装 Fail2ban
    apt install fail2ban -y || error_exit "Fail2ban安装失败"
    systemctl enable fail2ban
    systemctl start fail2ban
    success_msg "Fail2ban已安装并启动"
}

configure_fail2ban_ssh() {
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${RED}请先安装Fail2ban${NC}"
        return 1
    fi
    
    read -p "请输入最大尝试次数: " maxretry
    read -p "请输入封禁时间(秒，-1为永久): " bantime
    
    # 获取SSH端口，默认使用22端口
    port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
    if [ -z "$port" ]; then
        port=22  # 默认端口为22
    fi

    # 生成 Fail2ban 配置，添加 DEFAULT 部分
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = $bantime
findtime = 600
maxretry = $maxretry

[sshd]
enabled = true
port = $port
filter = sshd
logpath = /var/log/auth.log
maxretry = $maxretry
bantime = $bantime
findtime = 600
EOF

    # 重新启动 fail2ban 服务并检查其是否成功启动
    systemctl restart fail2ban
    if ! systemctl is-active --quiet fail2ban; then
        error_exit "Fail2ban服务启动失败"
    fi

    success_msg "Fail2ban SSH配置完成"
}

check_fail2ban_status() {
    if ! systemctl is-active --quiet fail2ban; then
        echo -e "${RED}Fail2ban服务未运行${NC}"
        return 1
    fi
    
    echo "Fail2ban状态:"
    fail2ban-client status
    echo "SSH状态:"
    fail2ban-client status sshd
}

# 5. ZeroTier配置
install_zerotier() {
    # 检查是否已安装
    if command -v zerotier-cli &> /dev/null; then
        echo -e "${YELLOW}ZeroTier已经安装${NC}"
        return 0
    fi

    # 安装ZeroTier
    curl -s https://install.zerotier.com | bash || error_exit "ZeroTier安装失败"
    
    # 启用并启动服务
    systemctl enable zerotier-one
    systemctl start zerotier-one
    
    # 等待服务完全启动
    sleep 5
    
    # 提示用户加入网络
    read -p "是否要加入ZeroTier网络? (y/n): " join_choice
    if [[ "$join_choice" == "y" ]]; then
        read -p "请输入ZeroTier网络ID: " network_id
        if [[ ! $network_id =~ ^[0-9a-f]{16}$ ]]; then
            error_exit "无效的网络ID格式"
        fi
        
        zerotier-cli join "$network_id"
    fi
    
    success_msg "ZeroTier已安装"
}

check_zerotier_status() {
    if ! command -v zerotier-cli &> /dev/null; then
        echo -e "${RED}ZeroTier未安装${NC}"
        return 1
    fi

    if ! systemctl is-active --quiet zerotier-one; then
        echo -e "${RED}ZeroTier服务未运行${NC}"
        return 1
    fi
    
    echo "ZeroTier状态:"
    zerotier-cli status
    echo "网络信息:"
    zerotier-cli listnetworks
}

configure_zerotier_ssh() {
    # 检查ZeroTier是否安装和运行
    if ! command -v zerotier-cli &> /dev/null; then
        echo -e "${RED}ZeroTier 未安装${NC}"
        return 1
    fi
    
    # 检查是否有活跃网络
    local network_count=$(zerotier-cli listnetworks 2>/dev/null | grep -c "OK")
    if [ "$network_count" -eq 0 ]; then
        echo -e "${YELLOW}未找到活跃的 ZeroTier 网络${NC}"
        read -p "是否要加入 ZeroTier 网络? (y/n): " join_network
        if [ "$join_network" = "y" ]; then
            read -p "请输入 ZeroTier 网络ID: " network_id
            if [[ ! $network_id =~ ^[0-9a-f]{16}$ ]]; then
                echo -e "${RED}无效的网络ID格式${NC}"
                return 1
            fi
            zerotier-cli join "$network_id"
            # 给网络一些时间建立连接
            sleep 3
        else
            return 1
        fi
    fi
    
    # 手动输入 ZeroTier 网络 IP 段
    read -p "请输入 ZeroTier 网络 IP 段(例如: 192.168.88.1/24): " zt_network
    
    # 验证输入的网络 IP 段格式
    if [[ ! "$zt_network" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo -e "${RED}无效的网络 IP 段格式。请使用 CIDR 表示法，例如 192.168.88.1/24${NC}"
        return 1
    fi
    
    # 获取当前 SSH 端口
    current_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
    
    # 使用 UFW 开放指定网段的 SSH 访问
    ufw allow from "$zt_network" to any port ${current_port:-22} proto tcp
    
    success_msg "已开放 ZeroTier 网段 $zt_network 的 SSH 访问"
}

# Docker 安装函数
install_docker() {
#    echo "正在使用 LinuxMirrors 脚本安装 Docker..."
#    bash <(curl -sSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/DockerInstallation.sh)
    echo "正在使用官方脚本安装 Docker..."
    curl -sSL https://get.docker.com/ | sh
    # 启动 Docker 服务
    sudo systemctl start docker
    # 设置 Docker 开机自启
    sudo systemctl enable docker
    success_msg "Docker 安装完成"
}

# Docker Compose 安装函数
install_docker_compose() {
    echo "正在安装 Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    success_msg "Docker Compose 安装完成"
}

# UFW Docker 配置函数
configure_ufw_docker() {
    echo "正在配置 UFW Docker 规则..."
    
    # 备份原始配置文件
    cp /etc/ufw/after.rules /etc/ufw/after.rules.backup
    
    # 追加 Docker UFW 规则
    cat >> /etc/ufw/after.rules << 'EOF'
# BEGIN UFW AND DOCKER
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
EOF

    # 重启 UFW
    systemctl restart ufw
    success_msg "UFW Docker 规则配置完成"
}

# Docker ufw端口开放函数
open_docker_port() {
    echo -e "${BLUE}选择开放端口类型：${NC}"
    echo -e "${YELLOW}1. 开放端口给所有公网IP${NC}"
    echo -e "${YELLOW}2. 开放端口给指定IP${NC}"
    echo -e "${GREEN}0. 返回上级菜单${NC}"
    
    read -p "请选择操作: " port_choice
    case $port_choice in
        1) 
            read -p "请输入要开放的端口号（容器的实际端口，而非主机映射端口，如-P 8080:80，则开放80端口）: " port
            sudo ufw route allow proto tcp from any to any port "$port"
            success_msg "已开放端口 $port 给所有公网IP"
            ;;
        2)
            read -p "请输入要开放的端口号: " port
            read -p "请输入指定的IP地址: " host_ip
            sudo ufw route allow from "$host_ip" to any port "$port"
            success_msg "已开放端口 $port 给 $host_ip"
            ;;
        0) 
            return 
            ;;
        *) 
            echo -e "${RED}无效的选择${NC}" 
            ;;
    esac
}

# Docker 容器信息展示函数
show_docker_container_info() {
    echo -e "${BLUE}======= Docker 容器信息 ========${NC}"
    
    # 检查是否安装了 Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker 未安装，无法显示容器信息${NC}"
        return
    fi

    # 容器列表信息
    echo -e "${YELLOW}容器列表：${NC}"
    docker ps -a --format "{{.Names}} | 状态：{{.Status}} | 镜像：{{.Image}}"
    
    echo -e "\n${YELLOW}详细容器信息：${NC}"
    docker ps -a --format "\
容器名称: {{.Names}}
容器ID: {{.ID}}
镜像: {{.Image}}
启动时间: {{.CreatedAt}}
状态: {{.Status}}
网络: {{.Networks}}
" | while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        echo -e "${GREEN}$line${NC}"
    fi
done

   # 网络信息
    echo -e "\n${YELLOW}Docker 网络及网关详细信息：${NC}"
    docker network ls --format "{{.Name}}" | while read -r network; do
        echo -e "${YELLOW}网络名称: $network${NC}"
        gateway=$(docker network inspect "$network" | grep -m 1 "Gateway" | awk -F'"' '{print $4}')
        if [[ -n "$gateway" ]]; then
            echo -e "${GREEN}网关: $gateway${NC}"
        else
            echo -e "${RED}未找到网关${NC}"
        fi
        echo "---"
    done
}
    # 网关信息
    echo -e "\n${YELLOW}网关详细信息：${NC}"
    docker network inspect bridge | grep Gateway
}

# 6. 1Panel安装
install_1panel() {
    read -p "是否安装1Panel? (y/n): " answer
    if [ "$answer" = "y" ]; then
        curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh && bash quick_start.sh
    fi
}

# 7. v2ray-agent安装
install_v2ray_agent() {
    read -p "是否安装v2ray-agent? (y/n): " answer
    if [ "$answer" = "y" ]; then
        wget -P /root -N --no-check-certificate https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh && chmod 700 /root/install.sh && /root/install.sh
    fi
}

# 子菜单 - SSH配置
ssh_menu() {
    while true; do
        echo -e "${BLUE}========= SSH配置菜单 ==========${NC}"
        echo -e "${YELLOW}1. 修改SSH端口${NC}"
        echo -e "${YELLOW}2. 查看当前SSH端口${NC}"
        echo -e "${YELLOW}3. 配置SSH密钥认证${NC}"
        echo -e "${GREEN}0. 返回主菜单${NC}"
        echo -e "${BLUE}================================${NC}"
        
        read -p "请选择操作: " choice
        case $choice in
            1) modify_ssh_port ;;
            2) check_ssh_port ;;
            3) configure_ssh_key ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        read -p "按回车键继续..."
    done
}

# 子菜单 - UFW配置
ufw_menu() {
    while true; do
        echo -e "${BLUE}========= UFW配置菜单 ==========${NC}"
        echo -e "${YELLOW}1. 安装UFW${NC}"
        echo -e "${YELLOW}2. 配置UFW并开放SSH端口${NC}"
        echo -e "${YELLOW}3. 配置UFW PING规则${NC}"
        echo -e "${YELLOW}4. 查看UFW状态${NC}"
        echo -e "${GREEN}0. 返回主菜单${NC}"
        echo -e "${BLUE}================================${NC}"
        
        read -p "请选择操作: " choice
        case $choice in
            1) install_ufw ;;
            2) configure_ufw ;;
            3) configure_ufw_ping ;;
            4) check_ufw_status ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        read -p "按回车键继续..."
    done
}

# 子菜单 - Fail2ban配置
fail2ban_menu() {
    while true; do
        echo -e "${BLUE}======== Fail2ban配置菜单 ========${NC}"
        echo -e "${YELLOW}1. 安装Fail2ban${NC}"
        echo -e "${YELLOW}2. 配置Fail2ban SSH防护${NC}"
        echo -e "${YELLOW}3. 查看Fail2ban状态${NC}"
        echo -e "${GREEN}0. 返回主菜单${NC}"
        echo -e "${BLUE}================================${NC}"
        
        read -p "请选择操作: " choice
        case $choice in
            1) install_fail2ban ;;
            2) configure_fail2ban_ssh ;;
            3) check_fail2ban_status ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        read -p "按回车键继续..."
    done
}

# 子菜单 - ZeroTier配置
zerotier_menu() {
    while true; do
        echo -e "${BLUE}======= ZeroTier配置菜单 ========${NC}"
        echo -e "${YELLOW}1. 安装并加入网络${NC}"
        echo -e "${YELLOW}2. 查看ZeroTier状态${NC}"
        echo -e "${YELLOW}3. 配置ZeroTier SSH访问${NC}"
        echo -e "${GREEN}0. 返回主菜单${NC}"
        echo -e "${BLUE}================================${NC}"
        
        read -p "请选择操作: " choice
        case $choice in
            1) install_zerotier ;;
            2) check_zerotier_status ;;
            3) configure_zerotier_ssh ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        read -p "按回车键继续..."
    done
}

# Docker 子菜单
docker_menu() {
    while true; do
        echo -e "${BLUE}======= Docker 配置菜单 ========${NC}"
        echo -e "${YELLOW}1. 安装 Docker${NC}"
        echo -e "${YELLOW}2. 安装 Docker Compose${NC}"
        echo -e "${YELLOW}3. 配置 UFW Docker 规则${NC}"
        echo -e "${YELLOW}4. 开放 Docker 端口${NC}"
        echo -e "${YELLOW}5. 查看 Docker 容器信息${NC}"
        echo -e "${GREEN}0. 返回主菜单${NC}"
        echo -e "${BLUE}================================${NC}"
        
        read -p "请选择操作: " choice
        case $choice in
            1) install_docker ;;
            2) install_docker_compose ;;
            3) configure_ufw_docker ;;
            4) open_docker_port ;;
            5) show_docker_container_info ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        read -p "按回车键继续..."
    done
}

# 清屏函数
clear_screen() {
    clear || echo -e "\n\n\n\n\n"
}

# 主菜单
main_menu() {
    while true; do
        clear_screen
        echo -e "${BLUE}${BOLD}===== 服务器简单 安全 配置菜单 =====${NC}"
        echo -e "${GREEN}${BOLD}1. 更新系统并安装curl${NC}"
        echo -e "${GREEN}${BOLD}2. SSH端口配置${NC}"
        echo -e "${GREEN}${BOLD}3. UFW防火墙配置${NC}"
        echo -e "${GREEN}${BOLD}4. Fail2ban配置${NC}"
        echo -e "${GREEN}${BOLD}5. ZeroTier配置${NC}"
        echo -e "${GREEN}${BOLD}6. Docker配置${NC}"  
        echo -e "${GREEN}${BOLD}7. 安装1Panel${NC}"
        echo -e "${GREEN}${BOLD}8. 安装v2ray-agent${NC}"
        echo -e "${RED}${BOLD}0. 退出${NC}"
        echo -e "${BLUE}${BOLD}====================================${NC}"
        
        read -p "请选择操作: " choice
        case $choice in
            1) system_update ;;
            2) ssh_menu ;;
            3) ufw_menu ;;
            4) fail2ban_menu ;;
            5) zerotier_menu ;;
            6) docker_menu ;;
            7) install_1panel ;;
            8) install_v2ray_agent ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        [ "$choice" != "0" ] && read -p "按回车键继续..."
    done
}

# 检查root权限
if [ "$EUID" -ne 0 ]; then 
    error_exit "请使用root权限运行此脚本"
fi

# 运行主菜单
main_menu
