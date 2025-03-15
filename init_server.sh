#!/bin/bash

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# 分隔线
show_separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 添加新的样式函数
show_header() {
    local title="$1"
    echo -e "\n${BLUE}┏━━━━━━━━━ ${BOLD}$title${NC}${BLUE} ━━━━━━━━━┓${NC}"
}

show_footer() {
    echo -e "${BLUE}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}\n"
}

show_menu_item() {
    local number="$1"
    local text="$2"
    echo -e "${BLUE}┃${NC} ${YELLOW}${number}${NC}. ${GREEN}${text}${NC}"
}

# 错误处理更严格
error_exit() {
    echo -e "${RED}错误: $1${NC}" >&2  # 将错误信息输出到stderr
    exit 1
}

# 添加日志记录功能
log_action() {
    local log_file="/var/log/server_config.log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$log_file" >/dev/null
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

# 1. 系统更新和curl安装
system_update() {
    echo "正在更新系统..."
    apt update && apt upgrade -y || error_exit "系统更新失败"    
    # 安装curl&net-tools
    apt install -y curl net-tools || error_exit "curl&netstat安装失败"    
    success_msg "系统更新完成，curl&netstat 已安装"
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

# 检查 authorized_keys 是否配置
check_authorized_keys() {
    local key_file=~/.ssh/authorized_keys
    if [ -f "$key_file" ]; then
        valid_keys=$(grep -cE '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp[0-9]+)' "$key_file")
        if [ "$valid_keys" -gt 0 ]; then
            echo -e "${GREEN}authorized_keys 文件已配置且包含 $valid_keys 个有效密钥${NC}"
            return 0
        else
            echo -e "${YELLOW}authorized_keys 文件存在但无有效密钥${NC}"
            return 1
        fi
    else
        echo -e "${RED}authorized_keys 文件不存在${NC}"
        return 2
    fi
}


# SSH公钥格式验证函数
validate_ssh_key() {
    local pubkey="$1"
    # 使用正则表达式验证标准SSH公钥格式
    if [[ "$pubkey" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/]+[=]{0,3}(\ [^@]+@[^ ]+)?$ ]]; then
        return 0
    else
        echo -e "${RED}错误：检测到无效的SSH公钥格式${NC}"
        return 1
    fi
}

# 修改SSH配置函数
modify_ssh_config() {
    local key=$1
    local value=$2
    local sshd_config="/etc/ssh/sshd_config"
    local backup_file="/etc/ssh/sshd_config.backup_$(date +%Y%m%d%H%M%S)"

    # 创建配置备份
    cp "$sshd_config" "$backup_file" || error_exit "无法创建配置文件备份"
    
    if grep -q "^${key}" "$sshd_config"; then
        sed -i "s/^${key}.*/${key} ${value}/" "$sshd_config"
    else
        echo "${key} ${value}" >> "$sshd_config"
    fi

    # 验证配置语法
    if ! sshd -t -f "$sshd_config"; then
        echo -e "${RED}错误：SSH配置语法错误，正在恢复备份...${NC}"
        cp "$backup_file" "$sshd_config"
        error_exit "SSH配置修改失败，已恢复备份"
    fi
}

# SSH密钥认证配置
configure_ssh_key() {
    check_authorized_keys
    local check_result=$?
    
    # 处理未配置密钥的情况
    if [ $check_result -ne 0 ]; then
        echo -e "${YELLOW}当前系统未配置有效的SSH密钥认证${NC}"
        read -p "是否立即配置SSH密钥认证？(y/n): " answer
        if [[ "$answer" =~ [Yy] ]]; then
            mkdir -p ~/.ssh || error_exit "无法创建.ssh目录"
            chmod 700 ~/.ssh
            
            # 密钥配置选项
            echo -e "${BLUE}请选择密钥配置方式：${NC}"
            PS3="请选择(1-3): "
            select key_method in "自动生成密钥" "手动粘贴密钥" "输入密钥内容"; do
                case $key_method in
                    "自动生成密钥")
                        ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" || error_exit "密钥生成失败"
                        cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
                        chmod 600 ~/.ssh/authorized_keys
                        success_msg "Ed25519密钥已生成并配置"
                        break
                        ;;
                    "手动粘贴密钥")
                        echo -e "${YELLOW}操作步骤：\n1. 本地执行 ssh-keygen -t ed25519\n2. 复制公钥内容（以ssh-ed25519开头）\n3. 粘贴到下方（Ctrl+D结束）${NC}"
                        if ! cat >> ~/.ssh/authorized_keys; then
                            error_exit "密钥写入失败"
                        fi
                        validate_ssh_key "$(cat ~/.ssh/authorized_keys)" || {
                            rm -f ~/.ssh/authorized_keys
                            error_exit "密钥验证失败"
                        }
                        break
                        ;;
                    "输入密钥内容")
                        read -r -p "请输入完整公钥: " pubkey
                        if validate_ssh_key "$pubkey"; then
                            echo "$pubkey" >> ~/.ssh/authorized_keys || error_exit "密钥写入失败"
                        fi
                        break
                        ;;
                    *)
                        echo -e "${RED}无效选择，请重试${NC}"
                        ;;
                esac
            done

            # 验证测试
            echo -e "${BLUE}正在进行连接验证..."
            if ! ssh -o PasswordAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=10 localhost true 2>/dev/null; then
                error_exit "本地连接测试失败，请检查密钥配置"
            fi
            success_msg "密钥验证通过"
        fi
    fi

    # 安全加固配置
    if [ $check_result -eq 0 ]; then
        echo -e "${YELLOW}当前存在有效密钥配置，建议执行安全加固："
        echo -e "▶ 禁用密码登录\n▶ 仅允许密钥认证的root登录\n▶ 禁用用户环境变量${NC}"
        
        read -p "是否立即执行安全加固？(y/n): " answer
        if [[ "$answer" =~ [Yy] ]]; then
            # 二次确认
            read -p "确认要应用以上配置吗？(输入YES确认，注意大小写): " confirm
            if [ "$confirm" != "YES" ]; then
                echo -e "${YELLOW}已取消安全加固${NC}"
                return
            fi

            # 修改关键配置
            modify_ssh_config "PermitRootLogin" "without-password"
            modify_ssh_config "PasswordAuthentication" "no"
            modify_ssh_config "PermitUserEnvironment" "no"
            modify_ssh_config "ChallengeResponseAuthentication" "no"
            modify_ssh_config "PermitEmptyPasswords" "no"

            # 重启服务
            if systemctl restart sshd; then
                echo -e "${GREEN}安全加固完成，当前配置："
                sshd -T | grep -E 'permitrootlogin|passwordauthentication|permituserenvironment'
            else
                error_exit "SSH服务重启失败，请检查日志：journalctl -u sshd"
            fi
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

# Fail2ban 状态检查函数
check_fail2ban_installation() {
    local status=0
    
    # 检查是否安装
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${RED}Fail2ban 未安装${NC}"
        return 1
    fi
    
    # 检查服务状态并尝试启动
    if ! systemctl is-active --quiet fail2ban; then
        echo -e "${YELLOW}Fail2ban 服务未运行，尝试启动...${NC}"
        systemctl start fail2ban
        sleep 2  # 等待服务启动
        if ! systemctl is-active --quiet fail2ban; then
            echo -e "${RED}Fail2ban 服务启动失败${NC}"
            return 2
        fi
    fi
    
    # 检查配置文件并创建
    if [ ! -f "/etc/fail2ban/jail.local" ]; then
        echo -e "${YELLOW}Fail2ban 配置文件未创建，正在创建默认配置...${NC}"
        cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
        if [ ! -f "/etc/fail2ban/jail.local" ]; then
            echo -e "${RED}配置文件创建失败${NC}"
            return 3
        fi
    fi
    
    return 0
}

# 安装 Fail2ban
install_fail2ban() {
    echo -e "${BLUE}开始安装 Fail2ban...${NC}"
    
    # 检查是否已安装
    if command -v fail2ban-client &> /dev/null; then
        echo -e "${YELLOW}Fail2ban 已安装，跳过安装步骤${NC}"
        return 0
    fi
    
    # 检查并安装依赖
    local dependencies=("rsyslog" "lsb-release")
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "安装依赖: $dep"
            apt-get install -y "$dep" || error_exit "$dep 安装失败"
        fi
    done
    
    # 确保 rsyslog 运行
    systemctl enable rsyslog
    systemctl start rsyslog
    
    # 安装 Fail2ban
    apt install fail2ban -y || error_exit "Fail2ban 安装失败"
    
    # 创建默认配置
    if [ ! -f "/etc/fail2ban/jail.local" ]; then
        cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    fi
    
    # 启动服务
    systemctl enable fail2ban
    systemctl start fail2ban
    
    success_msg "Fail2ban 安装完成"
}

# 配置 Fail2ban
configure_fail2ban_ssh() {
    # 首先确保服务正在运行
    if ! systemctl is-active --quiet fail2ban; then
        echo -e "${YELLOW}Fail2ban 服务未运行，正在启动...${NC}"
        systemctl start fail2ban
        sleep 3  # 增加等待时间
        
        if ! systemctl is-active --quiet fail2ban; then
            echo -e "${RED}Fail2ban 服务启动失败，尝试修复...${NC}"
            
            # 尝试修复服务
            systemctl stop fail2ban
            rm -f /var/run/fail2ban/fail2ban.sock 2>/dev/null
            systemctl start fail2ban
            sleep 3
            
            if ! systemctl is-active --quiet fail2ban; then
                error_exit "无法启动 Fail2ban 服务，请检查系统日志: journalctl -u fail2ban"
            fi
        fi
    fi

    # 检查并创建配置文件
    if [ ! -f "/etc/fail2ban/jail.local" ]; then
        echo -e "${YELLOW}Fail2ban 配置文件未创建，正在创建默认配置...${NC}"
        cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local || error_exit "无法创建配置文件"
    fi

    echo -e "\n${BLUE}配置 Fail2ban SSH 防护${NC}"
    
    # 验证输入
    while true; do
        read -p "请输入最大尝试次数 [3-10]: " maxretry
        if [[ "$maxretry" =~ ^[0-9]+$ ]] && [ "$maxretry" -ge 3 ] && [ "$maxretry" -le 10 ]; then
            break
        fi
        echo -e "${RED}无效的输入，请输入3-10之间的数字${NC}"
    done
    
    while true; do
        read -p "请输入封禁时间(秒，-1为永久) [600-86400 或 -1]: " bantime
        if [[ "$bantime" == "-1" ]] || ([[ "$bantime" =~ ^[0-9]+$ ]] && [ "$bantime" -ge 600 ] && [ "$bantime" -le 86400 ]); then
            break
        fi
        echo -e "${RED}无效的输入，请输入600-86400之间的数字或-1${NC}"
    done
    
    # 获取 SSH 端口
    local port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
    port=${port:-22}  # 默认使用 22 端口
    
    # 备份现有配置
    if [ -f "/etc/fail2ban/jail.local" ]; then
        cp /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.backup_$(date +%Y%m%d%H%M%S)"
    fi
    
    # 生成新配置
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = $bantime
findtime = 600
maxretry = $maxretry
banaction = iptables-multiport
banaction_allports = iptables-allports

[sshd]
enabled = true
port = $port
filter = sshd
logpath = /var/log/auth.log
maxretry = $maxretry
bantime = $bantime
findtime = 600
EOF
    
    # 确保日志文件存在
    touch /var/log/auth.log
    
    # 重启服务并等待
    echo -e "${YELLOW}正在重启 Fail2ban 服务...${NC}"
    systemctl restart fail2ban
    sleep 3
    
    # 验证服务状态
    if ! systemctl is-active --quiet fail2ban; then
        error_exit "Fail2ban 服务重启失败，请检查系统日志: journalctl -u fail2ban"
    fi
    
    # 等待 socket 文件创建
    for i in {1..5}; do
        if [ -S "/var/run/fail2ban/fail2ban.sock" ]; then
            break
        fi
        echo "等待服务就绪... ($i/5)"
        sleep 1
    done
    
    # 显示状态
    if [ -S "/var/run/fail2ban/fail2ban.sock" ]; then
        echo -e "\n${GREEN}Fail2ban 配置已更新，当前状态：${NC}"
        fail2ban-client status sshd
    else
        echo -e "${RED}警告：Fail2ban socket 文件未创建，但服务似乎在运行${NC}"
        echo "服务状态："
        systemctl status fail2ban --no-pager
    fi
}

# 查看 Fail2ban 状态
check_fail2ban_status() {
    check_fail2ban_installation
    local check_status=$?
    
    if [ $check_status -ne 0 ]; then
        return 1
    fi
    
    clear_screen
    show_header "Fail2ban 状态信息"
    
    echo -e "${BLUE}┃${NC} ${BOLD}服务状态${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(systemctl status fail2ban | head -n 3)
    
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}监狱状态${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(fail2ban-client status)
    
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}SSH 防护状态${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(fail2ban-client status sshd)
    
    show_footer
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

# 6. Docker 安装函数
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
    clear_screen
    show_header "Docker 容器资源信息"
    
    # 检查是否安装了 Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${BLUE}┃${NC} ${RED}Docker 未安装，无法显示容器信息${NC}"
        show_footer
        return
    fi

    # 检查 Docker 服务是否正常运行
    if ! docker info &> /dev/null; then
        echo -e "${BLUE}┃${NC} ${RED}Docker 服务未正常运行${NC}"
        show_footer
        return 1
    fi

    # 显示容器列表
    echo -e "${BLUE}┃${NC} ${BOLD}容器列表${NC}"
    echo -e "${BLUE}┃${NC}"
    docker ps -a --format "table ${BLUE}┃${NC} {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Networks}}"
    
    # 获取所有容器ID
    container_ids=$(docker ps -aq)
    
    if [ -n "$container_ids" ]; then
        for container_id in $container_ids; do
            echo -e "${BLUE}┃${NC}"
            echo -e "${BLUE}┣━━ ${YELLOW}容器详细信息${NC}"
            
            # 容器基本信息
            container_info=$(docker inspect --format "\
${BLUE}┃${NC}  ${GREEN}容器名称:${NC} {{.Name}}
${BLUE}┃${NC}  ${GREEN}容器ID:${NC} {{.Id}}
${BLUE}┃${NC}  ${GREEN}镜像:${NC} {{.Config.Image}}
${BLUE}┃${NC}  ${GREEN}启动时间:${NC} {{.Created}}
${BLUE}┃${NC}  ${GREEN}状态:${NC} {{.State.Status}}
${BLUE}┃${NC}  ${GREEN}网络:${NC} {{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}" "$container_id")
            echo -e "$container_info"
            
            echo -e "${BLUE}┃${NC}"
            echo -e "${BLUE}┣━━ ${YELLOW}资源使用情况${NC}"
            
            # 资源使用情况
            resource_info=$(docker stats "$container_id" --no-stream --format "\
${BLUE}┃${NC}  ${GREEN}CPU 使用率:${NC} {{.CPUPerc}}
${BLUE}┃${NC}  ${GREEN}内存使用:${NC} {{.MemUsage}}
${BLUE}┃${NC}  ${GREEN}网络 I/O:${NC} {{.NetIO}}
${BLUE}┃${NC}  ${GREEN}块 I/O:${NC} {{.BlockIO}}")
            echo -e "$resource_info"
            
            # 网关信息
            network_name=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' "$container_id")
            gateway=$(docker network inspect "$network_name" 2>/dev/null | grep -m 1 "Gateway" | awk -F'"' '{print $4}')
            
            if [[ -n "$gateway" ]]; then
                echo -e "${BLUE}┃${NC}  ${GREEN}网关:${NC} $gateway"
            fi
            
            echo -e "${BLUE}┃${NC}"
            echo -e "${BLUE}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        done
    else
        echo -e "${BLUE}┃${NC} ${YELLOW}当前没有运行的容器${NC}"
    fi
    
    # 显示总体资源使用情况
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${YELLOW}Docker 总体资源使用情况${NC}"
    echo -e "${BLUE}┃${NC}"
    docker system df | sed "s/^/${BLUE}┃${NC} /"
    
    show_footer
}

# 删除未使用的 Docker 资源
clean_docker_resources() {
    echo -e "${BLUE}======= Docker 资源清理 ========${NC}"
    
    # 检查 Docker 是否可用
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker 未安装，无法清理资源${NC}"
        return 1
    fi

    # 清理未使用的镜像
    echo -e "${YELLOW}正在清理未使用的镜像...${NC}"
    unused_images=$(docker images -f "dangling=true" -q)
    if [[ -n "$unused_images" ]]; then
        docker rmi $unused_images
        echo -e "${GREEN}未使用的镜像已删除${NC}"
    else
        echo -e "${GREEN}没有需要清理的未使用镜像${NC}"
    fi

    # 清理未使用的网络
    echo -e "\n${YELLOW}正在清理未使用的网络...${NC}"
    unused_networks=$(docker network ls -f "driver=bridge" -f "type=custom" | grep -v "NETWORK ID" | awk '{print $2}' | grep -v "bridge" | grep -v "host" | grep -v "none")
    
    if [[ -n "$unused_networks" ]]; then
        for network in $unused_networks; do
            # 检查网络是否正在被使用
            network_containers=$(docker network inspect "$network" -f '{{range .Containers}}{{.Name}} {{end}}')
            
            if [[ -z "$network_containers" ]]; then
                docker network rm "$network"
                echo -e "${GREEN}删除未使用网络: $network${NC}"
            else
                echo -e "${YELLOW}网络 $network 仍在使用，暂不删除${NC}"
            fi
        done
    else
        echo -e "${GREEN}没有需要清理的未使用网络${NC}"
    fi

    # 清理构建缓存
    echo -e "\n${YELLOW}清理 Docker 构建缓存...${NC}"
    docker builder prune -f

    # 显示清理后的空间
    echo -e "\n${YELLOW}Docker 资源清理后的空间情况：${NC}"
    docker system df
}

# 显示 Docker 网络详细信息
show_docker_networks() {
    clear_screen
    show_header "Docker 网络详细信息"
    
    # 检查 Docker 是否可用
    if ! command -v docker &> /dev/null; then
        echo -e "${BLUE}┃${NC} ${RED}Docker 未安装，无法显示网络信息${NC}"
        show_footer
        return 1
    fi

    # 列出所有网络
    echo -e "${BLUE}┃${NC} ${BOLD}网络列表${NC}"
    echo -e "${BLUE}┃${NC}"
    docker network ls | sed "s/^/${BLUE}┃${NC} /"
    
    # 显示每个网络的详细信息
    networks=$(docker network ls -q)
    
    if [ -n "$networks" ]; then
        for network in $networks; do
            echo -e "${BLUE}┃${NC}"
            echo -e "${BLUE}┣━━ ${YELLOW}网络详细信息${NC}"
            
            # 网络基本信息
            network_name=$(docker network inspect "$network" -f '{{.Name}}')
            network_driver=$(docker network inspect "$network" -f '{{.Driver}}')
            network_scope=$(docker network inspect "$network" -f '{{.Scope}}')
            
            echo -e "${BLUE}┃${NC}  ${GREEN}网络名称:${NC} $network_name"
            echo -e "${BLUE}┃${NC}  ${GREEN}网络驱动:${NC} $network_driver"
            echo -e "${BLUE}┃${NC}  ${GREEN}网络范围:${NC} $network_scope"
            
            # IPAM配置
            subnet=$(docker network inspect "$network" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
            gateway=$(docker network inspect "$network" -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
            
            echo -e "${BLUE}┃${NC}  ${GREEN}子网:${NC} $subnet"
            echo -e "${BLUE}┃${NC}  ${GREEN}网关:${NC} $gateway"
            
            # 连接的容器
            echo -e "${BLUE}┃${NC}"
            echo -e "${BLUE}┣━━ ${YELLOW}已连接容器${NC}"
            containers=$(docker network inspect "$network" -f '{{range .Containers}}{{.Name}} {{end}}')
            
            if [[ -n "$containers" ]]; then
                for container in $containers; do
                    echo -e "${BLUE}┃${NC}  • ${GREEN}$container${NC}"
                done
            else
                echo -e "${BLUE}┃${NC}  ${RED}无容器连接到此网络${NC}"
            fi
            
            echo -e "${BLUE}┃${NC}"
            echo -e "${BLUE}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        done
    else
        echo -e "${BLUE}┃${NC} ${YELLOW}未找到任何 Docker 网络${NC}"
    fi
    
    show_footer
}

# 7. 1Panel安装
install_1panel() {
    read -p "是否安装1Panel? (y/n): " answer
    if [ "$answer" = "y" ]; then
        curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh && bash quick_start.sh
    fi
}

# 8. v2ray-agent安装
install_v2ray_agent() {
    read -p "是否安装v2ray-agent? (y/n): " answer
    if [ "$answer" = "y" ]; then
        wget -P /root -N --no-check-certificate https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh && chmod 700 /root/install.sh && /root/install.sh
    fi
}

# 9.系统安全检查函数
system_security_check() {
    clear_screen
    show_header "系统安全检查"
    
    # 系统基本信息
    echo -e "${BLUE}┃${NC} ${BOLD}1. 系统基本信息${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(uname -a)
    
    # 当前登录用户
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}2. 当前登录用户${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(whoami)
    
    # 开放端口
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}3. 开放端口及监听服务${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(netstat -tuln | grep -E ":22\s|:80\s|:443\s")
    
    # 系统更新
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}4. 系统更新状态${NC}"
    echo -e "${BLUE}┃${NC}"
    if command -v apt &> /dev/null; then
        while IFS= read -r line; do
            echo -e "${BLUE}┃${NC} $line"
        done < <(apt list --upgradable 2>/dev/null | head -n 5)
    else
        echo -e "${BLUE}┃${NC} ${YELLOW}不支持的包管理器${NC}"
    fi
    
    # 登录记录
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}5. 最近登录记录${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(last -a | head -n 5)
    
    # SSH配置
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}6. SSH 安全配置${NC}"
    echo -e "${BLUE}┃${NC}"
    if [ -f /etc/ssh/sshd_config ]; then
        while IFS= read -r line; do
            echo -e "${BLUE}┃${NC} $line"
        done < <(sshd -T 2>/dev/null | grep -E "permituserenvironment|permitrootlogin|passwordauthentication")
    else
        echo -e "${BLUE}┃${NC} ${RED}SSH 配置文件不存在${NC}"
    fi
    
    # 防火墙状态
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}7. 防火墙状态${NC}"
    echo -e "${BLUE}┃${NC}"
    if command -v ufw &> /dev/null; then
        while IFS= read -r line; do
            echo -e "${BLUE}┃${NC} $line"
        done < <(ufw status)
    else
        echo -e "${BLUE}┃${NC} ${YELLOW}UFW 未安装${NC}"
    fi
    
    show_footer
}

# 10. 系统安全加固前的确认函数
system_security_hardening() {
    echo -e "${RED}警告：系统安全加固将对系统配置进行重大更改！${NC}"
    read -p "是否确定要进行系统安全加固？(yes/no): " confirm

    if [[ "$confirm" == "yes" ]]; then
        echo -e "${YELLOW}开始系统安全加固...${NC}"
        
        # 备份关键配置文件
        sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
        sudo cp /etc/security/pwquality.conf /etc/security/pwquality.conf.backup

        # 执行安全加固
        sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y
        
        # 禁用不必要的服务
        sudo systemctl disable bluetooth
        sudo systemctl disable cups
        
        # 设置最大登录尝试次数和超时
        sudo sed -i 's/.*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
        sudo sed -i 's/.*LoginGraceTime.*/LoginGraceTime 30s/' /etc/ssh/sshd_config
        
        # 设置更严格的密码策略
        sudo apt-get install -y libpam-pwquality
        sudo bash -c 'cat << EOF > /etc/security/pwquality.conf
minlen = 12
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
EOF'
        
        # 重启 SSH 服务
        sudo systemctl restart ssh
        
        echo -e "${GREEN}系统安全加固完成！${NC}"
        echo -e "${YELLOW}建议：${NC}"
        echo -e "1. 检查并测试所有系统服务"
        echo -e "2. 确认远程访问仍然正常"
        echo -e "3. 如需还原，可使用备份文件"
    else
        echo -e "${GREEN}已取消系统安全加固${NC}"
    fi
}

# 11. 资源监控函数
system_resource_monitor() {
    clear_screen
    show_header "系统资源监控"
    
    # CPU信息
    echo -e "${BLUE}┃${NC} ${BOLD}CPU 信息${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(lscpu | grep -E "Model name|Socket|Core|Thread")
    
    # 内存使用
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}内存使用情况${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(free -h)
    
    # 磁盘使用
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}磁盘使用情况${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(df -h)
    
    # CPU负载
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}CPU 负载${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(uptime)
    
    show_footer
}

# 12. 网络诊断函数
network_diagnostic() {
    clear_screen
    show_header "网络诊断"
    
    # 公网连接测试
    echo -e "${BLUE}┃${NC} ${BOLD}公网连接测试${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(ping -c 4 8.8.8.8)
    
    # DNS解析测试
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}DNS 解析测试${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(dig google.com +short)
    
    # 路由追踪
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}路由追踪${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(traceroute -n google.com | head -n 5)
    
    # 网络接口
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}网络接口信息${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(ip addr | grep -E "^[0-9]:|inet")
    
    show_footer
}

# SSH配置子菜单
ssh_menu() {
    while true; do
        clear_screen
        show_header "SSH 配置管理"
        
        show_menu_item "1" "修改SSH端口"
        show_menu_item "2" "查看当前SSH端口"
        show_menu_item "3" "配置SSH密钥认证"
        
        echo -e "${BLUE}┃${NC}"
        show_menu_item "0" "返回主菜单"
        
        show_footer
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-3]: "${NC})" choice
        case $choice in
            1) modify_ssh_port ;;
            2) check_ssh_port ;;
            3) configure_ssh_key ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        [ "$choice" != "0" ] && read -p "$(echo -e ${YELLOW}"按回车键继续..."${NC})"
    done
}

# UFW配置子菜单
ufw_menu() {
    while true; do
        clear_screen
        show_header "UFW 防火墙配置"
        
        show_menu_item "1" "安装UFW"
        show_menu_item "2" "配置UFW并开放SSH端口"
        show_menu_item "3" "配置UFW PING规则"
        show_menu_item "4" "查看UFW状态"
        
        echo -e "${BLUE}┃${NC}"
        show_menu_item "0" "返回主菜单"
        
        show_footer
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-4]: "${NC})" choice
        case $choice in
            1) install_ufw ;;
            2) configure_ufw ;;
            3) configure_ufw_ping ;;
            4) check_ufw_status ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        [ "$choice" != "0" ] && read -p "$(echo -e ${YELLOW}"按回车键继续..."${NC})"
    done
}

# Fail2ban配置子菜单
fail2ban_menu() {
    while true; do
        clear_screen
        show_header "Fail2ban 配置管理"
        
        show_menu_item "1" "安装Fail2ban"
        show_menu_item "2" "配置Fail2ban SSH防护"
        show_menu_item "3" "查看Fail2ban状态"
        
        echo -e "${BLUE}┃${NC}"
        show_menu_item "0" "返回主菜单"
        
        show_footer
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-3]: "${NC})" choice
        case $choice in
            1) install_fail2ban ;;
            2) configure_fail2ban_ssh ;;
            3) check_fail2ban_status ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        [ "$choice" != "0" ] && read -p "$(echo -e ${YELLOW}"按回车键继续..."${NC})"
    done
}

# ZeroTier配置子菜单
zerotier_menu() {
    while true; do
        clear_screen
        show_header "ZeroTier 配置管理"
        
        show_menu_item "1" "安装并加入网络"
        show_menu_item "2" "查看ZeroTier状态"
        show_menu_item "3" "配置ZeroTier SSH访问"
        
        echo -e "${BLUE}┃${NC}"
        show_menu_item "0" "返回主菜单"
        
        show_footer
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-3]: "${NC})" choice
        case $choice in
            1) install_zerotier ;;
            2) check_zerotier_status ;;
            3) configure_zerotier_ssh ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        [ "$choice" != "0" ] && read -p "$(echo -e ${YELLOW}"按回车键继续..."${NC})"
    done
}

# Docker配置子菜单
docker_menu() {
    while true; do
        clear_screen
        show_header "Docker 配置管理"
        
        echo -e "${BLUE}┃${NC} ${BOLD}基础配置${NC}"
        show_menu_item "1" "安装 Docker"
        show_menu_item "2" "安装 Docker Compose"
        
        echo -e "\n${BLUE}┃${NC} ${BOLD}网络配置${NC}"
        show_menu_item "3" "配置 UFW Docker 规则"
        show_menu_item "4" "开放 Docker 端口"
        
        echo -e "\n${BLUE}┃${NC} ${BOLD}系统管理${NC}"
        show_menu_item "5" "查看 Docker 容器信息"
        show_menu_item "6" "清理 Docker 资源"
        show_menu_item "7" "查看 Docker 网络信息"
        
        echo -e "${BLUE}┃${NC}"
        show_menu_item "0" "返回主菜单"
        
        show_footer
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-7]: "${NC})" choice
        case $choice in
            1) install_docker ;;
            2) install_docker_compose ;;
            3) configure_ufw_docker ;;
            4) open_docker_port ;;
            5) show_docker_container_info ;;
            6) clean_docker_resources ;;
            7) show_docker_networks ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        [ "$choice" != "0" ] && read -p "$(echo -e ${YELLOW}"按回车键继续..."${NC})"
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
        show_header "服务器配置管理系统"
        
        # 系统管理
        echo -e "${BLUE}┃${NC} ${BOLD}系统管理${NC}"
        show_menu_item "01" "更新系统"
        show_menu_item "02" "SSH端口配置"
        show_menu_item "03" "UFW防火墙配置"
        show_menu_item "04" "Fail2ban配置"
        show_menu_item "05" "ZeroTier配置"
        show_menu_item "06" "Docker配置"
        
        # 应用安装
        echo -e "\n${BLUE}┃${NC} ${BOLD}应用安装${NC}"
        show_menu_item "07" "安装1Panel"
        show_menu_item "08" "安装v2ray-agent"
        
        # 系统工具
        echo -e "\n${BLUE}┃${NC} ${BOLD}系统工具${NC}"
        show_menu_item "09" "系统安全检查"
        show_menu_item "10" "系统安全加固"
        show_menu_item "11" "系统资源监控"
        show_menu_item "12" "网络诊断"
        
        echo -e "${BLUE}┃${NC}"
        show_menu_item "0" "退出系统"
        
        show_footer
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-12]: "${NC})" choice
        
        case $choice in
            1) system_update ;;
            2) ssh_menu ;;
            3) ufw_menu ;;
            4) fail2ban_menu ;;
            5) zerotier_menu ;;
            6) docker_menu ;;
            7) install_1panel ;;
            8) install_v2ray_agent ;;
            9) system_security_check ;;
            10) system_security_hardening ;;
            11) system_resource_monitor ;;
            12) network_diagnostic ;;
            0) 
                clear_screen
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0 
                ;;
            *) echo -e "${RED}无效的选择，请重试${NC}" ;;
        esac
        [ "$choice" != "0" ] && read -p "$(echo -e ${YELLOW}"按回车键继续..."${NC})"
    done
}

# 检查root权限
if [ "$EUID" -ne 0 ]; then 
    error_exit "请使用root权限运行此脚本"
fi

# 运行主菜单
main_menu
