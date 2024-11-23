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
    if ! command -v $service_name &> /dev/null; then
        echo -e "${RED}错误: $service_name 未安装${NC}"
        return 1
    fi
    
    if ! systemctl is-active --quiet $service_name; then
        echo -e "${YELLOW}警告: $service_name 服务未运行${NC}"
        return 1
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
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}请先安装UFW${NC}"
        return 1
    fi  
    
    read -p "是否禁止PING? (y/n): " answer
    if [ "$answer" = "y" ]; then
        ufw insert 1 deny proto icmp || error_exit "UFW配置PING规则失败"
        success_msg "已禁止PING"
    fi
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
    curl -s https://install.zerotier.com | bash || error_exit "ZeroTier安装失败"
    systemctl enable zerotier-one
    systemctl start zerotier-one
    
    # 等待服务完全启动
    sleep 5
    
    read -p "请输入ZeroTier网络ID: " network_id
    if [[ ! $network_id =~ ^[0-9a-f]{16}$ ]]; then
        error_exit "无效的网络ID格式"
    fi
    
    zerotier-cli join "$network_id"
    success_msg "ZeroTier已安装并加入网络"
}

check_zerotier_status() {
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
    if ! check_installed zerotier-cli; then
        return 1
    fi
    
    read -p "请输入ZeroTier虚拟IP段(例如: 192.168.192.0/24): " zt_network
    current_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
    ufw allow from "$zt_network" to any port ${current_port:-22} proto tcp
    success_msg "已开放ZeroTier网段的SSH访问"
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

# 清屏函数
clear_screen() {
    clear || echo -e "\n\n\n\n\n"
}

# 主菜单
main_menu() {
    while true; do
        clear_screen
        echo -e "${BLUE}${BOLD}===== 服务器 简单安全 配置菜单 =====${NC}"
        echo -e "${GREEN}${BOLD}1. 更新系统并安装curl${NC}"
        show_separator
        echo -e "${GREEN}${BOLD}2. SSH端口配置${NC}"
        show_separator
        echo -e "${GREEN}${BOLD}3. UFW防火墙配置${NC}"
        show_separator
        echo -e "${GREEN}${BOLD}4. Fail2ban配置${NC}"
        show_separator
        echo -e "${GREEN}${BOLD}5. ZeroTier配置${NC}"
        show_separator
        echo -e "${GREEN}${BOLD}6. 安装1Panel${NC}"
        show_separator
        echo -e "${GREEN}${BOLD}7. 安装v2ray-agent${NC}"
        show_separator
        echo -e "${RED}${BOLD}0. 退出${NC}"
        echo -e "${BLUE}${BOLD}====================================${NC}"
        
        read -p "请选择操作: " choice
        case $choice in
            1) system_update ;;
            2) ssh_menu ;;
            3) ufw_menu ;;
            4) fail2ban_menu ;;
            5) zerotier_menu ;;
            6) install_1panel ;;
            7) install_v2ray_agent ;;
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
