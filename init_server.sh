#!/bin/bash

# ============================================
# 服务器配置管理系统
# 版本: 1.3.1
# ============================================
VERSION="1.3.1"

# 设置脚本选项增强健壮性
set -o pipefail

# 终端检测：非终端环境禁用颜色
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    BLUE=''
    YELLOW=''
    CYAN=''
    WHITE=''
    MAGENTA=''
    BOLD=''
    DIM=''
    NC=''
fi

# 临时文件清理
cleanup() {
    local exit_code=$?
    # 清理可能存在的临时文件
    rm -f /tmp/test_daemon.json 2>/dev/null
    rm -f /etc/docker/daemon.json.tmp 2>/dev/null
    exit $exit_code
}
trap cleanup EXIT INT TERM

# 依赖检查
check_dependencies() {
    local missing_deps=()
    local deps=("systemctl" "grep" "sed" "awk")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}错误: 缺少必要的系统命令: ${missing_deps[*]}${NC}" >&2
        exit 1
    fi
}

# 封装确认操作函数
confirm_action() {
    local prompt="${1:-确认操作}"
    local answer
    read -p "$prompt (y/n): " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# 封装带边框的输出函数
print_boxed() {
    while IFS= read -r line; do
        echo -e "$line"
    done
}

# 处理Docker输出格式的函数
format_docker_output() {
    # 替换可能未正确解析的ANSI颜色码
    sed 's/33\[0;34m/\\033[0;34m/g' | sed 's/33\[0m/\\033[0m/g' | sed 's/\\033/\033/g' | sed 's/\\0\\033/\033/g' | sed 's/\\0\\0/\0/g'
}

# 分隔线
show_separator() {
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
}

# 页面标题
show_header() {
    local title="$1"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} $title${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo ""
}

# 页面底部
show_footer() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
}

# 菜单项
show_menu_item() {
    local number="$1"
    local text="$2"
    echo -e "  ${YELLOW}${number}${NC}. ${GREEN}${text}${NC}"
}

# ============================================
# UI 美化函数
# ============================================

# 横幅
show_banner() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}       ${BOLD}服务器配置管理系统${NC}${CYAN}  v${VERSION}${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════${NC}"
}

# 进度条函数
get_progress_bar() {
    local percent=$1
    local width=15
    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    
    local color
    if [ "$percent" -lt 50 ]; then
        color="${GREEN}"
    elif [ "$percent" -lt 80 ]; then
        color="${YELLOW}"
    else
        color="${RED}"
    fi
    
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    
    echo -en "${color}${bar}${NC} ${percent}%"
}

# 系统信息仪表盘
show_dashboard() {
    echo ""
    echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
    echo -e "${BOLD} 📊 系统信息${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
    
    # 主机名和内核
    local hostname=$(hostname 2>/dev/null || echo "未知")
    local kernel=$(uname -r 2>/dev/null || echo "未知")
    echo -e " ${CYAN}主机名:${NC} ${hostname}   ${CYAN}内核:${NC} ${kernel}"
    
    # 操作系统
    local os_info="未知"
    if [ -f /etc/os-release ]; then
        os_info=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    fi
    echo -e " ${CYAN}系统:${NC} ${os_info}"
    
    echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
    
    # CPU 使用率
    local cpu_usage=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print int($2 + $4)}' || echo "0")
    [ -z "$cpu_usage" ] && cpu_usage=0
    echo -en " ${YELLOW}CPU:${NC}  "
    get_progress_bar "$cpu_usage"
    echo ""
    
    # 内存使用 - 使用更健壮的解析方式兼容不同系统
    local mem_info=$(free -m 2>/dev/null | awk '/Mem:/ {print $2, $3}')
    local mem_total=$(echo "$mem_info" | awk '{print $1}')
    local mem_used=$(echo "$mem_info" | awk '{print $2}')
    # 确保值为数字
    [[ ! "$mem_total" =~ ^[0-9]+$ ]] && mem_total=0
    [[ ! "$mem_used" =~ ^[0-9]+$ ]] && mem_used=0
    local mem_percent=0
    [ "$mem_total" -gt 0 ] && mem_percent=$((mem_used * 100 / mem_total))
    echo -en " ${YELLOW}内存:${NC} "
    get_progress_bar "$mem_percent"
    echo -e " ${DIM}${mem_used}/${mem_total}MB${NC}"
    
    # 磁盘使用
    local disk_percent=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')
    local disk_used=$(df -h / 2>/dev/null | awk 'NR==2 {print $3}')
    local disk_total=$(df -h / 2>/dev/null | awk 'NR==2 {print $2}')
    [ -z "$disk_percent" ] && disk_percent=0
    echo -en " ${YELLOW}磁盘:${NC} "
    get_progress_bar "$disk_percent"
    echo -e " ${DIM}${disk_used}/${disk_total}${NC}"
    
    echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
    
    # IP 地址和运行时间
    local ipv4=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -1)
    local uptime_info=$(uptime -p 2>/dev/null | sed 's/up //')
    echo -e " ${GREEN}IP:${NC} ${ipv4:-未检测到}   ${GREEN}运行:${NC} ${uptime_info}"
    
    # 时区和时间
    local timezone=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')
    local current_time=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e " ${GREEN}时区:${NC} ${timezone:-未知}   ${GREEN}时间:${NC} ${current_time}"
    
    echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
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


# 功能函数
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
    
    # 检查端口是否被占用
    if netstat -tuln 2>/dev/null | grep -q ":${new_port}\s" || ss -tuln 2>/dev/null | grep -q ":${new_port}\s"; then
        echo -e "${YELLOW}警告: 端口 $new_port 可能已被占用${NC}"
        read -p "是否继续修改? (y/n): " continue_modify
        if [[ ! "$continue_modify" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}操作已取消${NC}"
            return 1
        fi
    fi
    
    # 备份配置文件
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)
    
    # 稳健替换：匹配注释行/前导空格，若无 Port 行则追加
    if grep -qE '^\s*#?\s*Port\s+[0-9]+' /etc/ssh/sshd_config; then
        sed -i -E "s/^\s*#?\s*Port\s+[0-9]+/Port ${new_port}/" /etc/ssh/sshd_config
    else
        echo "Port ${new_port}" >> /etc/ssh/sshd_config
    fi

    # 验证配置语法，失败则回滚
    if ! sshd -t 2>/dev/null; then
        echo -e "${RED}SSH配置语法错误，正在恢复备份...${NC}"
        cp "$(ls -t /etc/ssh/sshd_config.bak.* | head -1)" /etc/ssh/sshd_config
        error_exit "SSH配置修改失败"
    fi

    systemctl restart sshd 2>/dev/null || systemctl restart ssh || error_exit "SSH重启失败"
    success_msg "SSH端口已修改为: $new_port"
    echo -e "${YELLOW}重要: 请确保防火墙已开放新端口 $new_port${NC}"
    echo -e "${CYAN}当前生效配置:${NC}"
    sshd -T 2>/dev/null | grep -E '^port '
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
    
    # 同时处理已激活行和注释行（如出厂 #PubkeyAuthentication no）
    if grep -qE "^\s*#?\s*${key}\s" "$sshd_config"; then
        sed -i -E "s/^\s*#?\s*${key}\s.*/${key} ${value}/" "$sshd_config"
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
                        # 逐行校验，至少一行有效即通过
                        local any_valid=0
                        while IFS= read -r line; do
                            [[ -z "$line" || "$line" =~ ^# ]] && continue
                            if validate_ssh_key "$line" 2>/dev/null; then
                                any_valid=1; break
                            fi
                        done < ~/.ssh/authorized_keys
                        if [ "$any_valid" -eq 0 ]; then
                            rm -f ~/.ssh/authorized_keys
                            error_exit "密钥验证失败：无有效公钥行"
                        fi
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
            echo -e "${BLUE}正在进行连接验证...${NC}"
            if ! ssh -o PasswordAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=5 localhost true 2>/dev/null; then
                echo -e "${YELLOW}警告: 本地连接测试失败，但密钥可能已正确配置${NC}"
                echo -e "${YELLOW}可能原因: 本地SSH服务配置、防火墙或localhost解析问题${NC}"
                echo -e "${YELLOW}如果您可以从其他设备使用密钥正常连接，则可以忽略此警告${NC}"
            else
                success_msg "密钥验证通过"
            fi
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

            # 防锁死检查：禁用密码前必须有有效密钥
            if ! check_authorized_keys > /dev/null 2>&1; then
                echo -e "${RED}错误：~/.ssh/authorized_keys 不存在或无有效密钥，中止加固以防锁死${NC}"
                return 1
            fi

            echo -e "${YELLOW}⚠ 建议保持当前会话/控制台窗口，待新连接验证成功后再关闭${NC}"

            # 修改关键配置（顺序：先开公钥，再改 root 登录，最后禁密码）
            modify_ssh_config "PubkeyAuthentication" "yes"
            modify_ssh_config "PermitRootLogin" "prohibit-password"
            modify_ssh_config "PasswordAuthentication" "no"
            modify_ssh_config "PermitUserEnvironment" "no"
            modify_ssh_config "ChallengeResponseAuthentication" "no"
            modify_ssh_config "PermitEmptyPasswords" "no"

            # 重启服务（兼容 Debian/Ubuntu 与 RHEL）
            if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
                echo -e "${GREEN}安全加固完成，当前生效配置：${NC}"
                sshd -T 2>/dev/null | grep -E 'port|pubkeyauthentication|passwordauthentication|permitrootlogin|authorizedkeysfile'
                echo -e "${YELLOW}⚠ 请立即用新会话测试 SSH 密钥登录，确认无误后再关闭当前会话${NC}"
            else
                error_exit "SSH服务重启失败，请检查日志：journalctl -u sshd"
            fi
        fi
    fi
}


# 3. UFW防火墙配置
install_ufw() {
    # 检查是否已安装
    if command -v ufw &> /dev/null; then
        echo -e "${YELLOW}UFW 已安装${NC}"
        ufw version
        read -p "是否重新安装/更新 UFW? (y/n): " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    
    # 更新包索引并安装
    echo -e "${BLUE}正在更新包索引并安装 UFW...${NC}"
    apt update && apt install ufw -y || error_exit "UFW安装失败"
    
    # 重要：启用前先允许SSH，防止锁定远程访问
    echo -e "${YELLOW}正在配置默认规则，确保SSH访问不会被阻断...${NC}"
    current_port=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    ufw allow "${current_port:-22}/tcp" comment 'SSH'
    
    # 设置默认策略
    ufw default deny incoming
    ufw default allow outgoing
    
    # 启用UFW服务
    systemctl enable ufw
    
    # 使用 --force 避免交互式确认
    echo -e "${BLUE}正在启用 UFW 防火墙...${NC}"
    if ufw --force enable; then
        success_msg "UFW已安装并成功启用"
        echo -e "${GREEN}当前防火墙状态：${NC}"
        ufw status verbose
    else
        echo -e "${RED}UFW启用失败，请手动检查：ufw status${NC}"
        return 1
    fi
}

# 卸载 UFW
uninstall_ufw() {
    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}UFW 未安装${NC}"
        return 0
    fi
    
    echo -e "${RED}警告: 卸载 UFW 将移除所有防火墙规则！${NC}"
    read -p "确定要卸载 UFW 吗? (输入 yes 确认): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}已取消卸载${NC}"
        return 0
    fi
    
    echo -e "${BLUE}正在禁用并卸载 UFW...${NC}"
    ufw --force disable 2>/dev/null
    apt purge ufw -y && apt autoremove -y
    
    if ! command -v ufw &> /dev/null; then
        success_msg "UFW 已成功卸载"
    else
        echo -e "${RED}卸载失败${NC}"
        return 1
    fi
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
    clear_screen
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} 📋 UFW 规则列表${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}UFW 未安装${NC}"
        return 1
    fi
    
    local status=$(ufw status 2>/dev/null | head -1)
    if ! echo "$status" | grep -q "active"; then
        echo -e "${RED}防火墙未启用${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        return
    fi
    
    # 规则列表
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    printf " ${BOLD}%-25s  %-12s  %s${NC}\n" "端口" "动作" "来源"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    
    ufw status 2>/dev/null | grep -E "ALLOW|DENY" | while read -r line; do
        local port=$(echo "$line" | awk '{print $1}')
        local action=$(echo "$line" | awk '{print $2}')
        local from=$(echo "$line" | awk '{print $3}')
        
        local action_color="${GREEN}"
        [[ "$action" == "DENY" ]] && action_color="${RED}"
        
        printf " %-25s  ${action_color}%-12s${NC}  %s\n" "$port" "$action" "$from"
    done
    
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
}

# 开放端口到指定IP
open_port_to_ip() {
    clear_screen
    show_header "开放端口到指定IP"
    
    # 验证UFW是否已安装
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}请先安装UFW${NC}"
        return 1
    fi
    
    # 获取端口信息
    read -p "请输入要开放的端口号: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}无效的端口号，请输入1-65535之间的数字${NC}"
        return 1
    fi
    
    # 获取协议
    echo -e "${BLUE}请选择协议:${NC}"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP和UDP"
    read -p "选择协议 [1-3]: " proto_choice
    
    case $proto_choice in
        1) protocol="tcp" ;;
        2) protocol="udp" ;;
        3) protocol="tcp,udp" ;;
        *) 
            echo -e "${RED}无效的选择${NC}"
            return 1
            ;;
    esac
    
    # 获取IP地址
    read -p "请输入允许访问的IP地址: " ip_address
    
    # 验证IP地址格式
    if ! [[ $ip_address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo -e "${RED}无效的IP地址格式${NC}"
        return 1
    fi
    
    # 确认操作
    echo -e "${YELLOW}将开放端口 $port/$protocol 给IP $ip_address${NC}"
    read -p "确认操作? (y/n): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 执行UFW规则添加
        if [[ "$protocol" == "tcp,udp" ]]; then
            ufw allow proto tcp from "$ip_address" to any port "$port"
            ufw allow proto udp from "$ip_address" to any port "$port"
            success_msg "已开放端口 $port 的TCP和UDP协议给IP $ip_address"
        else
            ufw allow proto "$protocol" from "$ip_address" to any port "$port"
            success_msg "已开放端口 $port/$protocol 给IP $ip_address"
        fi
    else
        echo -e "${YELLOW}操作已取消${NC}"
    fi
    
    show_footer
}

# 批量端口管理
manage_batch_ports() {
    clear_screen
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} 🔧 UFW 批量端口管理${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 验证UFW是否已安装
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}请先安装UFW${NC}"
        return 1
    fi
    
    # 显示当前规则数量
    local rule_count=$(ufw status 2>/dev/null | grep -c "ALLOW\|DENY" || echo "0")
    echo -e " ${CYAN}当前规则数:${NC} ${rule_count}"
    echo ""
    
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    show_menu_item "1" "批量开放端口"
    show_menu_item "2" "批量关闭端口"
    show_menu_item "3" "批量开放端口到特定IP"
    show_menu_item "4" "批量删除UFW规则"
    echo ""
    show_menu_item "0" "返回"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    
    read -p "$(echo -e ${YELLOW}"选择操作 [0-4]: "${NC})" batch_choice
    
    case $batch_choice in
        1) batch_open_ports ;;
        2) batch_close_ports ;;
        3) batch_open_ports_to_ip ;;
        4) batch_delete_ufw_rules ;;
        0) return ;;
        *) 
            echo -e "${RED}无效的选择${NC}"
            return 1
            ;;
    esac
}

# 批量删除UFW规则
batch_delete_ufw_rules() {
    clear_screen
    show_header "批量删除UFW规则"
    
    # 显示当前规则并编号
    echo -e "${BLUE}当前UFW规则:${NC}"
    echo ""
    
    # 使用更灵活的正则表达式匹配带编号的规则
    mapfile -t rules < <(ufw status numbered | grep -E '^\[[ 0-9]+\]')
    
    if [ ${#rules[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有找到任何UFW规则${NC}"
        read -p "按回车键返回..." -r
        return
    fi
    
    # 显示规则列表（带颜色格式化）
    echo -e "${BOLD}     端口/协议                    动作        来源${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
    for i in "${!rules[@]}"; do
        echo -e " ${rules[$i]}"
    done
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
    echo -e " ${DIM}共 ${#rules[@]} 条规则${NC}"
    
    echo ""
    echo -e "${YELLOW}删除选项:${NC}"
    echo "1. 按范围删除规则 (从大到小安全删除)"
    echo "2. 按规则号删除多条规则"
    echo "3. 按规则内容删除 (最安全)"
    echo "0. 返回"
    
    read -p "选择操作 [0-3]: " delete_choice
    
    case $delete_choice in
        1)
            echo -e "${YELLOW}请指定要删除的规则范围${NC}"
            read -p "起始规则号: " start_num
            read -p "结束规则号: " end_num
            
            # 验证输入
            if ! [[ "$start_num" =~ ^[0-9]+$ ]] || ! [[ "$end_num" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}无效的规则号${NC}"
                return 1
            fi
            
            if [ "$start_num" -gt "$end_num" ]; then
                echo -e "${RED}起始规则号不能大于结束规则号${NC}"
                return 1
            fi
            
            if [ "$start_num" -lt 1 ] || [ "$end_num" -gt ${#rules[@]} ]; then
                echo -e "${RED}规则号超出范围${NC}"
                return 1
            fi
            
            # 确认删除
            echo -e "${RED}警告: 将删除从 $start_num 到 $end_num 的规则${NC}"
            read -p "确认删除? (y/n): " confirm
            
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # 需要从后向前删除，避免规则号变化
                for ((i=end_num; i>=start_num; i--)); do
                    # 从规则行中提取实际的规则号
                    local rule_num=$(echo "${rules[$i-1]}" | grep -oE '^\[[ ]*([0-9]+)\]' | tr -d '[]' | tr -d ' ')
                    echo -e "${YELLOW}删除规则 $rule_num: ${rules[$i-1]}${NC}"
                    # 使用yes命令自动确认删除
                    yes | ufw delete "$rule_num"
                done
                echo -e "${GREEN}批量删除完成${NC}"
            else
                echo -e "${YELLOW}操作已取消${NC}"
            fi
            ;;
            
        2)
            echo -e "${YELLOW}请输入要删除的规则号，多个规则号用逗号分隔 (例如: 1,3,5)${NC}"
            read -p "规则号列表: " rule_nums
            
            # 验证格式
            if ! [[ $rule_nums =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                echo -e "${RED}无效的格式，请使用逗号分隔的数字${NC}"
                return 1
            fi
            
            # 转换为数组并排序（降序）
            IFS=',' read -ra RULE_ARRAY <<< "$rule_nums"
            RULE_ARRAY=($(echo "${RULE_ARRAY[@]}" | tr ' ' '\n' | sort -nr | tr '\n' ' '))
            
            # 验证规则号是否在有效范围内
            for num in "${RULE_ARRAY[@]}"; do
                if [ "$num" -lt 1 ] || [ "$num" -gt ${#rules[@]} ]; then
                    echo -e "${RED}规则号 $num 超出范围${NC}"
                    return 1
                fi
            done
            
            # 确认删除
            echo -e "${RED}警告: 将删除以下规则号: ${RULE_ARRAY[*]}${NC}"
            read -p "确认删除? (y/n): " confirm
            
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # 从大到小删除，避免规则号变化
                for num in "${RULE_ARRAY[@]}"; do
                    # 从规则行中提取实际的规则号
                    local rule_num=$(echo "${rules[$num-1]}" | grep -oE '^\[[ ]*([0-9]+)\]' | tr -d '[]' | tr -d ' ')
                    echo -e "${YELLOW}删除规则 $rule_num: ${rules[$num-1]}${NC}"
                    yes | ufw delete "$rule_num"
                done
                echo -e "${GREEN}批量删除完成${NC}"
            else
                echo -e "${YELLOW}操作已取消${NC}"
            fi
            ;;
        
        3)
            # 按规则内容删除 - 最安全的方式
            echo -e "${CYAN}按规则内容删除 (输入规则的关键信息)${NC}"
            echo -e "${DIM}示例: 删除所有来自 103.21.244.0/22 的规则${NC}"
            echo ""
            echo -e "1. 删除包含特定IP/网段的所有规则"
            echo -e "2. 删除特定端口的所有规则"
            echo -e "3. 删除特定端口+IP组合的规则"
            echo -e "0. 返回"
            
            read -p "选择删除类型 [0-3]: " content_choice
            
            case $content_choice in
                1)
                    read -p "输入要删除的IP或网段 (例如: 103.21.244.0/22): " target_ip
                    if [ -z "$target_ip" ]; then
                        echo -e "${RED}未输入IP${NC}"
                        return 1
                    fi
                    
                    # 查找匹配的规则
                    echo -e "\n${YELLOW}找到以下匹配规则:${NC}"
                    local match_count=0
                    for rule in "${rules[@]}"; do
                        if echo "$rule" | grep -q "$target_ip"; then
                            echo -e " ${rule}"
                            ((match_count++))
                        fi
                    done
                    
                    if [ "$match_count" -eq 0 ]; then
                        echo -e "${YELLOW}未找到匹配的规则${NC}"
                        return 0
                    fi
                    
                    echo -e "\n${RED}将删除以上 $match_count 条规则${NC}"
                    read -p "确认删除? (y/n): " confirm
                    
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        # 从后向前遍历删除
                        for ((i=${#rules[@]}-1; i>=0; i--)); do
                            if echo "${rules[$i]}" | grep -q "$target_ip"; then
                                local rule_num=$(echo "${rules[$i]}" | grep -oE '^\[[ ]*([0-9]+)\]' | tr -d '[]' | tr -d ' ')
                                echo -e "${YELLOW}删除: ${rules[$i]}${NC}"
                                yes | ufw delete "$rule_num"
                            fi
                        done
                        echo -e "${GREEN}删除完成${NC}"
                    fi
                    ;;
                2)
                    read -p "输入要删除的端口 (例如: 80 或 80/tcp): " target_port
                    if [ -z "$target_port" ]; then
                        echo -e "${RED}未输入端口${NC}"
                        return 1
                    fi
                    
                    echo -e "\n${YELLOW}找到以下匹配规则:${NC}"
                    local match_count=0
                    for rule in "${rules[@]}"; do
                        if echo "$rule" | grep -qE "^\\[[ 0-9]+\\] ${target_port}[^0-9]|^\\[[ 0-9]+\\] ${target_port}\$"; then
                            echo -e " ${rule}"
                            ((match_count++))
                        fi
                    done
                    
                    if [ "$match_count" -eq 0 ]; then
                        echo -e "${YELLOW}未找到匹配的规则${NC}"
                        return 0
                    fi
                    
                    echo -e "\n${RED}将删除以上 $match_count 条规则${NC}"
                    read -p "确认删除? (y/n): " confirm
                    
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        for ((i=${#rules[@]}-1; i>=0; i--)); do
                            if echo "${rules[$i]}" | grep -qE "^\\[[ 0-9]+\\] ${target_port}[^0-9]|^\\[[ 0-9]+\\] ${target_port}\$"; then
                                local rule_num=$(echo "${rules[$i]}" | grep -oE '^\[[ ]*([0-9]+)\]' | tr -d '[]' | tr -d ' ')
                                echo -e "${YELLOW}删除: ${rules[$i]}${NC}"
                                yes | ufw delete "$rule_num"
                            fi
                        done
                        echo -e "${GREEN}删除完成${NC}"
                    fi
                    ;;
                3)
                    read -p "输入端口 (例如: 80/tcp): " target_port
                    read -p "输入来源IP/网段 (例如: 103.21.244.0/22): " target_ip
                    
                    if [ -z "$target_port" ] || [ -z "$target_ip" ]; then
                        echo -e "${RED}端口和IP都需要输入${NC}"
                        return 1
                    fi
                    
                    echo -e "\n${YELLOW}找到以下匹配规则:${NC}"
                    local match_count=0
                    for rule in "${rules[@]}"; do
                        if echo "$rule" | grep -q "$target_port" && echo "$rule" | grep -q "$target_ip"; then
                            echo -e " ${rule}"
                            ((match_count++))
                        fi
                    done
                    
                    if [ "$match_count" -eq 0 ]; then
                        echo -e "${YELLOW}未找到匹配的规则${NC}"
                        return 0
                    fi
                    
                    echo -e "\n${RED}将删除以上 $match_count 条规则${NC}"
                    read -p "确认删除? (y/n): " confirm
                    
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        for ((i=${#rules[@]}-1; i>=0; i--)); do
                            if echo "${rules[$i]}" | grep -q "$target_port" && echo "${rules[$i]}" | grep -q "$target_ip"; then
                                local rule_num=$(echo "${rules[$i]}" | grep -oE '^\[[ ]*([0-9]+)\]' | tr -d '[]' | tr -d ' ')
                                echo -e "${YELLOW}删除: ${rules[$i]}${NC}"
                                yes | ufw delete "$rule_num"
                            fi
                        done
                        echo -e "${GREEN}删除完成${NC}"
                    fi
                    ;;
                0) return ;;
                *) echo -e "${RED}无效的选择${NC}" ;;
            esac
            ;;
            
        0)
            return
            ;;
            
        *)
            echo -e "${RED}无效的选择${NC}"
            return 1
            ;;
    esac
    
    # 显示更新后的规则状态
    echo -e "\n${BLUE}更新后的UFW规则:${NC}"
    ufw status numbered
    
    read -p "按回车键继续..." -r
}

# 批量开放端口
batch_open_ports() {
    echo -e "${BLUE}请输入要开放的端口，多个端口用逗号分隔 (例如: 80,443,8080)${NC}"
    read -p "端口列表: " port_list
    
    # 验证端口格式
    if ! [[ $port_list =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo -e "${RED}无效的端口格式，请使用逗号分隔的数字${NC}"
        return 1
    fi
    
    echo -e "${BLUE}请选择协议:${NC}"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP和UDP"
    read -p "选择协议 [1-3]: " proto_choice
    
    case $proto_choice in
        1) protocol="tcp" ;;
        2) protocol="udp" ;;
        3) protocol="both" ;;
        *) 
            echo -e "${RED}无效的选择${NC}"
            return 1
            ;;
    esac
    
    # 确认操作
    local ports_count=$(echo $port_list | tr ',' '\n' | wc -l)
    echo -e "${YELLOW}将批量开放 $ports_count 个端口，协议: $protocol${NC}"
    echo -e "${YELLOW}端口列表: $port_list${NC}"
    read -p "确认操作? (y/n): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local success_count=0
        local failed_ports=""
        
        # 处理每个端口
        IFS=',' read -ra PORTS <<< "$port_list"
        for port in "${PORTS[@]}"; do
            if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
                echo -e "${RED}跳过无效端口: $port${NC}"
                failed_ports="$failed_ports,$port"
                continue
            fi
            
            # 添加规则
            if [ "$protocol" = "both" ]; then
                if ufw allow $port/tcp && ufw allow $port/udp; then
                    echo -e "${GREEN}已开放端口 $port (TCP/UDP)${NC}"
                    ((success_count++))
                else
                    echo -e "${RED}开放端口 $port 失败${NC}"
                    failed_ports="$failed_ports,$port"
                fi
            else
                if ufw allow $port/$protocol; then
                    echo -e "${GREEN}已开放端口 $port/$protocol${NC}"
                    ((success_count++))
                else
                    echo -e "${RED}开放端口 $port/$protocol 失败${NC}"
                    failed_ports="$failed_ports,$port"
                fi
            fi
        done
        
        # 总结结果
        echo -e "\n${BLUE}批量操作完成:${NC}"
        echo -e "${GREEN}成功: $success_count 个端口${NC}"
        
        if [ -n "$failed_ports" ]; then
            # 去掉第一个逗号
            failed_ports=${failed_ports:1}
            echo -e "${RED}失败: $failed_ports${NC}"
        fi
    else
        echo -e "${YELLOW}操作已取消${NC}"
    fi
}

# 批量关闭端口
batch_close_ports() {
    echo -e "${BLUE}请输入要关闭的端口，多个端口用逗号分隔 (例如: 80,443,8080)${NC}"
    read -p "端口列表: " port_list
    
    # 验证端口格式
    if ! [[ $port_list =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo -e "${RED}无效的端口格式，请使用逗号分隔的数字${NC}"
        return 1
    fi
    
    echo -e "${BLUE}请选择协议:${NC}"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP和UDP"
    read -p "选择协议 [1-3]: " proto_choice
    
    case $proto_choice in
        1) protocol="tcp" ;;
        2) protocol="udp" ;;
        3) protocol="both" ;;
        *) 
            echo -e "${RED}无效的选择${NC}"
            return 1
            ;;
    esac
    
    # 确认操作
    local ports_count=$(echo $port_list | tr ',' '\n' | wc -l)
    echo -e "${YELLOW}将批量关闭 $ports_count 个端口，协议: $protocol${NC}"
    echo -e "${YELLOW}端口列表: $port_list${NC}"
    read -p "确认操作? (y/n): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local success_count=0
        local failed_ports=""
        
        # 处理每个端口
        IFS=',' read -ra PORTS <<< "$port_list"
        for port in "${PORTS[@]}"; do
            if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
                echo -e "${RED}跳过无效端口: $port${NC}"
                failed_ports="$failed_ports,$port"
                continue
            fi
            
            # 删除规则
            if [ "$protocol" = "both" ]; then
                if ufw delete allow $port/tcp && ufw delete allow $port/udp; then
                    echo -e "${GREEN}已关闭端口 $port (TCP/UDP)${NC}"
                    ((success_count++))
                else
                    echo -e "${RED}关闭端口 $port 失败${NC}"
                    failed_ports="$failed_ports,$port"
                fi
            else
                if ufw delete allow $port/$protocol; then
                    echo -e "${GREEN}已关闭端口 $port/$protocol${NC}"
                    ((success_count++))
                else
                    echo -e "${RED}关闭端口 $port/$protocol 失败${NC}"
                    failed_ports="$failed_ports,$port"
                fi
            fi
        done
        
        # 总结结果
        echo -e "\n${BLUE}批量操作完成:${NC}"
        echo -e "${GREEN}成功: $success_count 个端口${NC}"
        
        if [ -n "$failed_ports" ]; then
            # 去掉第一个逗号
            failed_ports=${failed_ports:1}
            echo -e "${RED}失败: $failed_ports${NC}"
        fi
    else
        echo -e "${YELLOW}操作已取消${NC}"
    fi
}

# 批量开放端口到特定IP
batch_open_ports_to_ip() {
    echo -e "${BLUE}请输入要开放的端口，多个端口用逗号分隔 (例如: 80,443,8080)${NC}"
    read -p "端口列表: " port_list
    
    # 验证端口格式
    if ! [[ $port_list =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo -e "${RED}无效的端口格式，请使用逗号分隔的数字${NC}"
        return 1
    fi
    
    echo -e "${BLUE}请选择协议:${NC}"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP和UDP"
    read -p "选择协议 [1-3]: " proto_choice
    
    case $proto_choice in
        1) protocol="tcp" ;;
        2) protocol="udp" ;;
        3) protocol="both" ;;
        *) 
            echo -e "${RED}无效的选择${NC}"
            return 1
            ;;
    esac
    
    # 获取IP地址
    read -p "请输入允许访问的IP地址: " ip_address
    
    # 验证IP地址格式
    if ! [[ $ip_address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo -e "${RED}无效的IP地址格式${NC}"
        return 1
    fi
    
    # 确认操作
    local ports_count=$(echo $port_list | tr ',' '\n' | wc -l)
    echo -e "${YELLOW}将批量开放 $ports_count 个端口到IP $ip_address，协议: $protocol${NC}"
    echo -e "${YELLOW}端口列表: $port_list${NC}"
    read -p "确认操作? (y/n): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local success_count=0
        local failed_ports=""
        
        # 处理每个端口
        IFS=',' read -ra PORTS <<< "$port_list"
        for port in "${PORTS[@]}"; do
            if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
                echo -e "${RED}跳过无效端口: $port${NC}"
                failed_ports="$failed_ports,$port"
                continue
            fi
            
            # 添加规则
            if [ "$protocol" = "both" ]; then
                if ufw allow proto tcp from "$ip_address" to any port "$port" && \
                   ufw allow proto udp from "$ip_address" to any port "$port"; then
                    echo -e "${GREEN}已开放端口 $port (TCP/UDP) 到IP $ip_address${NC}"
                    ((success_count++))
                else
                    echo -e "${RED}开放端口 $port 到IP $ip_address 失败${NC}"
                    failed_ports="$failed_ports,$port"
                fi
            else
                if ufw allow proto "$protocol" from "$ip_address" to any port "$port"; then
                    echo -e "${GREEN}已开放端口 $port/$protocol 到IP $ip_address${NC}"
                    ((success_count++))
                else
                    echo -e "${RED}开放端口 $port/$protocol 到IP $ip_address 失败${NC}"
                    failed_ports="$failed_ports,$port"
                fi
            fi
        done
        
        # 总结结果
        echo -e "\n${BLUE}批量操作完成:${NC}"
        echo -e "${GREEN}成功: $success_count 个端口${NC}"
        
        if [ -n "$failed_ports" ]; then
            # 去掉第一个逗号
            failed_ports=${failed_ports:1}
            echo -e "${RED}失败: $failed_ports${NC}"
        fi
    else
        echo -e "${YELLOW}操作已取消${NC}"
    fi
}

# 4. Fail2ban相关函数
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

    # 确保日志文件存在（rsyslog 可能尚未写入）
    touch /var/log/auth.log

    # 创建默认配置
    if [ ! -f "/etc/fail2ban/jail.local" ]; then
        cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    fi

    # 启动服务
    systemctl enable fail2ban
    systemctl start fail2ban
    sleep 2

    if systemctl is-active --quiet fail2ban; then
        success_msg "Fail2ban 安装完成并已启动"
    else
        echo -e "${YELLOW}Fail2ban 已安装，但启动失败，请执行: journalctl -u fail2ban -n 20 查看原因${NC}"
    fi
}

# 卸载 Fail2ban
uninstall_fail2ban() {
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${YELLOW}Fail2ban 未安装${NC}"
        return 0
    fi
    
    echo -e "${RED}警告: 卸载 Fail2ban 将移除所有防护规则！${NC}"
    read -p "确定要卸载 Fail2ban 吗? (输入 yes 确认): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}已取消卸载${NC}"
        return 0
    fi
    
    echo -e "${BLUE}正在停止并卸载 Fail2ban...${NC}"
    systemctl stop fail2ban 2>/dev/null
    systemctl disable fail2ban 2>/dev/null
    apt purge fail2ban -y && apt autoremove -y
    
    # 清理配置文件
    rm -rf /etc/fail2ban 2>/dev/null
    
    if ! command -v fail2ban-client &> /dev/null; then
        success_msg "Fail2ban 已成功卸载"
    else
        echo -e "${RED}卸载失败${NC}"
        return 1
    fi
}

# 配置 Fail2ban
configure_fail2ban_ssh() {
    # 首先确保服务正在运行
    if ! systemctl is-active --quiet fail2ban; then
        echo -e "${YELLOW}Fail2ban 服务未运行，正在启动...${NC}"
        # 确保日志文件存在，避免 fail2ban 因找不到 auth.log 而退出
        touch /var/log/auth.log
        rm -f /var/run/fail2ban/fail2ban.sock 2>/dev/null
        systemctl start fail2ban
        sleep 3

        if ! systemctl is-active --quiet fail2ban; then
            echo -e "${RED}Fail2ban 服务启动失败，请查看: journalctl -u fail2ban -n 30${NC}"
            error_exit "无法启动 Fail2ban 服务"
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
    
    # 确定日志后端：优先 auth.log，不存在则用 systemd journal
    local logpath="/var/log/auth.log"
    local backend="auto"
    if [ ! -f "$logpath" ]; then
        touch "$logpath" 2>/dev/null || { logpath=""; backend="systemd"; }
    fi

    # 生成新配置
    {
        cat << EOF
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
EOF
        [ -n "$logpath" ] && echo "logpath = $logpath"
        [ "$backend" = "systemd" ] && echo "backend = systemd"
        cat << EOF
maxretry = $maxretry
bantime = $bantime
findtime = 600
EOF
    } > /etc/fail2ban/jail.local

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
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} 🚫 Fail2ban 状态信息${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 服务状态
    echo -e "${BOLD} 📊 服务状态${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    local f2b_active=$(systemctl is-active fail2ban 2>/dev/null)
    if [ "$f2b_active" == "active" ]; then
        local uptime=$(systemctl show fail2ban --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
        echo -e " 状态: ${GREEN}● 运行中${NC}   启动时间: ${uptime}"
    else
        echo -e " 状态: ${RED}● 未运行${NC}"
    fi
    echo ""
    
    # 监狱概览
    echo -e "${BOLD} 🔒 监狱概览${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    local jail_count=$(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk '{print $NF}')
    local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2 | xargs)
    echo -e " 监狱数: ${CYAN}${jail_count:-0}${NC}   列表: ${jails:-无}"
    echo ""
    
    # 各监狱详细状态
    echo -e "${BOLD} 📋 监狱详情${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    
    # 遍历每个监狱
    for jail in $(echo "$jails" | tr ',' ' '); do
        jail=$(echo "$jail" | xargs)  # 去除空格
        [ -z "$jail" ] && continue
        
        local status=$(fail2ban-client status "$jail" 2>/dev/null)
        local cur_banned=$(echo "$status" | grep "Currently banned" | awk '{print $NF}')
        local total_banned=$(echo "$status" | grep "Total banned" | awk '{print $NF}')
        local cur_failed=$(echo "$status" | grep "Currently failed" | awk '{print $NF}')
        local total_failed=$(echo "$status" | grep "Total failed" | awk '{print $NF}')
        
        # 从配置文件获取 jail 配置
        local jail_port=$(grep -A 10 "^\[$jail\]" /etc/fail2ban/jail.local 2>/dev/null | grep "^port" | head -1 | awk -F'=' '{print $2}' | xargs)
        local jail_maxretry=$(grep -A 10 "^\[$jail\]" /etc/fail2ban/jail.local 2>/dev/null | grep "^maxretry" | head -1 | awk -F'=' '{print $2}' | xargs)
        local jail_bantime=$(grep -A 10 "^\[$jail\]" /etc/fail2ban/jail.local 2>/dev/null | grep "^bantime" | head -1 | awk -F'=' '{print $2}' | xargs)
        local jail_findtime=$(grep -A 10 "^\[$jail\]" /etc/fail2ban/jail.local 2>/dev/null | grep "^findtime" | head -1 | awk -F'=' '{print $2}' | xargs)
        
        # 颜色标记当前封禁
        local ban_color="${NC}"
        [ "${cur_banned:-0}" -gt 0 ] && ban_color="${RED}"
        
        # bantime 显示
        local bantime_display="${jail_bantime:-默认}"
        [ "$jail_bantime" == "-1" ] && bantime_display="永久"
        
        echo -e " ${CYAN}[$jail]${NC}"
        echo -e "   端口: ${jail_port:-ssh}   最大重试: ${jail_maxretry:-5}次   封禁时间: ${bantime_display}   检测周期: ${jail_findtime:-600}秒"
        echo -e "   当前封禁: ${ban_color}${cur_banned:-0}${NC}   总封禁: ${total_banned:-0}   当前失败: ${cur_failed:-0}   总失败: ${total_failed:-0}"
        echo ""
    done
    
    echo ""
    
    # 当前封禁的IP
    local banned_ips=$(fail2ban-client status sshd 2>/dev/null | grep "Banned IP list" | cut -d: -f2 | xargs)
    if [ -n "$banned_ips" ]; then
        echo -e "${BOLD} 🚷 SSH 当前封禁IP${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
        echo -e " ${RED}${banned_ips}${NC}"
        echo ""
    fi
    
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
}

# 注意: install_fail2ban 函数已在第 884-920 行定义，此处删除重复定义

# 5. ZeroTier配置相关函数
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

# 卸载 ZeroTier
uninstall_zerotier() {
    if ! command -v zerotier-cli &> /dev/null; then
        echo -e "${YELLOW}ZeroTier 未安装${NC}"
        return 0
    fi
    
    echo -e "${RED}警告: 卸载 ZeroTier 将断开所有 ZeroTier 网络连接！${NC}"
    read -p "确定要卸载 ZeroTier 吗? (输入 yes 确认): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}已取消卸载${NC}"
        return 0
    fi
    
    # 先离开所有网络
    echo -e "${BLUE}正在离开所有 ZeroTier 网络...${NC}"
    for network in $(zerotier-cli listnetworks 2>/dev/null | awk 'NR>1 {print $3}'); do
        zerotier-cli leave "$network" 2>/dev/null
    done
    
    echo -e "${BLUE}正在停止并卸载 ZeroTier...${NC}"
    systemctl stop zerotier-one 2>/dev/null
    systemctl disable zerotier-one 2>/dev/null
    apt purge zerotier-one -y && apt autoremove -y
    
    # 清理配置
    rm -rf /var/lib/zerotier-one 2>/dev/null
    
    if ! command -v zerotier-cli &> /dev/null; then
        success_msg "ZeroTier 已成功卸载"
    else
        echo -e "${RED}卸载失败${NC}"
        return 1
    fi
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

# 6. Docker相关函数
#  Docker 安装函数
install_docker() {
    # 检查是否已安装
    if command -v docker &> /dev/null; then
        echo -e "${YELLOW}Docker 已安装${NC}"
        docker --version
        read -p "是否重新安装/更新 Docker? (y/n): " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    
    echo -e "${BLUE}正在下载 Docker 安装脚本...${NC}"
    local script_file="/tmp/get-docker.sh"
    
    # 下载脚本而不是直接执行
    if ! curl -fsSL https://get.docker.com -o "$script_file"; then
        error_exit "Docker 安装脚本下载失败"
    fi
    
    # 检查脚本是否有效
    if [ ! -s "$script_file" ]; then
        error_exit "下载的脚本文件为空"
    fi
    
    echo -e "${BLUE}正在安装 Docker...${NC}"
    if ! sh "$script_file"; then
        rm -f "$script_file"
        error_exit "Docker 安装失败"
    fi
    
    rm -f "$script_file"
    
    # 启动 Docker 服务
    systemctl start docker || error_exit "Docker 服务启动失败"
    # 设置 Docker 开机自启
    systemctl enable docker
    
    # 验证安装
    if docker --version &> /dev/null; then
        success_msg "Docker 安装完成"
        docker --version
    else
        error_exit "Docker 安装后验证失败"
    fi
}

# 卸载 Docker
uninstall_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}Docker 未安装${NC}"
        return 0
    fi
    
    echo -e "${RED}警告: 卸载 Docker 将删除所有容器、镜像和卷！${NC}"
    local running=$(docker ps -q 2>/dev/null | wc -l)
    local total=$(docker ps -aq 2>/dev/null | wc -l)
    local images=$(docker images -q 2>/dev/null | wc -l)
    echo -e " ${CYAN}当前状态:${NC} 容器 ${total} 个 (运行中 ${running})，镜像 ${images} 个"
    
    read -p "确定要卸载 Docker 吗? (输入 yes 确认): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}已取消卸载${NC}"
        return 0
    fi
    
    echo -e "${BLUE}正在停止所有容器...${NC}"
    docker stop $(docker ps -aq) 2>/dev/null
    
    echo -e "${BLUE}正在删除所有容器和镜像...${NC}"
    docker rm $(docker ps -aq) 2>/dev/null
    docker rmi $(docker images -q) 2>/dev/null
    
    echo -e "${BLUE}正在卸载 Docker...${NC}"
    systemctl stop docker 2>/dev/null
    systemctl disable docker 2>/dev/null
    apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y 2>/dev/null
    apt autoremove -y
    
    # 清理数据
    rm -rf /var/lib/docker 2>/dev/null
    rm -rf /var/lib/containerd 2>/dev/null
    rm -f /usr/local/bin/docker-compose 2>/dev/null
    
    if ! command -v docker &> /dev/null; then
        success_msg "Docker 已成功卸载"
    else
        echo -e "${RED}卸载可能不完整，请手动检查${NC}"
        return 1
    fi
}

# Docker Compose 安装函数
install_docker_compose() {
    # 检查是否已内置 docker compose
    if docker compose version &> /dev/null; then
        echo -e "${GREEN}检测到 Docker 已内置 Compose 插件${NC}"
        docker compose version
        read -p "是否仍要安装独立版 docker-compose? (y/n): " install_standalone
        if [[ ! "$install_standalone" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}跳过安装${NC}"
            return 0
        fi
    fi
    
    echo "正在安装 Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    success_msg "Docker Compose 安装完成"
}

# 添加进度条/等待提示函数
show_loading() {
    local message="$1"
    local duration=${2:-8}  # 默认等待40秒
    local i=0
    
    echo -ne "${YELLOW}$message "
    while [ $i -lt $duration ]; do
        for s in / - \\ \|; do  
            echo -ne "\b$s"
            sleep 0.25
        done
        i=$((i+1))
    done
    echo -ne "\b${NC}"
    echo ""
}

# Docker 镜像加速配置函数
configure_docker_mirror() {
    clear_screen
    show_header "Docker 镜像加速配置"
    
    # 检查Docker是否安装
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker 未安装，请先安装 Docker${NC}"
        show_footer
        return 1
    fi
    
    echo -e "${BOLD} Docker 镜像加速配置${NC}"
    echo -e ""
    
    # 检查当前配置
    if [ -f "/etc/docker/daemon.json" ]; then
        echo -e "${GREEN}当前配置的镜像加速:${NC}"
        echo -e ""
        # 提取镜像URL并以简单格式显示
        mirrors=$(grep -o '"https://[^"]*"' /etc/docker/daemon.json)
        if [ -n "$mirrors" ]; then
            echo "$mirrors" | sed 's/"//g' | while read -r url; do
                echo -e " • $url"
            done
        else
            echo -e " 无法解析镜像URL，查看原始配置:"
            cat /etc/docker/daemon.json | while read -r line; do
                echo -e "   $line"
            done
        fi
        echo -e ""
    else
        echo -e "${YELLOW}当前未配置镜像加速${NC}"
        echo -e ""
    fi
    
    echo -e "1) 配置镜像加速"
    echo -e "2) 删除镜像加速配置"
    echo -e "0) 返回上级菜单"
    echo -e ""
    
    read -p "$(echo -e ${YELLOW}"请选择操作 [0-2]: "${NC})" choice
    
    case $choice in
        1)
            echo -e ""
            echo -e "请输入您要使用的 Docker 镜像加速地址:"
            read -p "$(echo -e ${YELLOW}"> "${NC})" mirror_url
            
            if [ -z "$mirror_url" ]; then
                echo -e "${RED}未提供镜像加速地址，操作取消${NC}"
                show_footer
                return 1
            fi
            
            # 创建或更新daemon.json文件
            mkdir -p /etc/docker
            
            # 测试镜像配置开始
            echo -e "${YELLOW}正在测试镜像地址有效性...${NC}"
            # 创建临时配置文件
            echo "{\"registry-mirrors\": [\"$mirror_url\"]}" > /tmp/test_daemon.json

            # 临时备份当前配置
            if [ -f "/etc/docker/daemon.json" ]; then
                cp /etc/docker/daemon.json /etc/docker/daemon.json.tmp
            fi

            # 应用测试配置
            cp /tmp/test_daemon.json /etc/docker/daemon.json

            # 测试Docker是否能启动
            show_loading "测试镜像配置" 30
            if ! systemctl restart docker; then
                echo -e "${RED}使用此镜像地址无法启动Docker，可能是镜像地址无效${NC}"
                echo -e "${YELLOW}正在恢复原配置...${NC}"
                # 恢复原配置
                if [ -f "/etc/docker/daemon.json.tmp" ]; then
                    cp /etc/docker/daemon.json.tmp /etc/docker/daemon.json
                    rm /etc/docker/daemon.json.tmp
                    show_loading "恢复原配置" 3
                    systemctl restart docker
                fi
                show_footer
                return 1
            fi

            # 如果成功，清理临时文件
            if [ -f "/etc/docker/daemon.json.tmp" ]; then
                rm /etc/docker/daemon.json.tmp
            fi
            echo -e "${GREEN}镜像地址测试通过!${NC}"
            
            if [ -f "/etc/docker/daemon.json" ]; then
                # 创建备份
                cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)
                
                # 检查是否已有registry-mirrors配置
                if grep -q "registry-mirrors" /etc/docker/daemon.json; then
                    # 使用jq更新镜像（如果安装了jq）
                    if command -v jq &> /dev/null; then
                        tmp_file=$(mktemp)
                        jq --arg mirror "$mirror_url" '.["registry-mirrors"] = [$mirror]' /etc/docker/daemon.json > "$tmp_file"
                        mv "$tmp_file" /etc/docker/daemon.json
                    else
                        # 简单的sed替换（不够健壮，但对简单配置有效）
                        sed -i "s|\"registry-mirrors\":\s*\[[^]]*\]|\"registry-mirrors\": [\"$mirror_url\"]|g" /etc/docker/daemon.json
                    fi
                else
                    # 需要添加registry-mirrors字段
                    if command -v jq &> /dev/null; then
                        tmp_file=$(mktemp)
                        jq --arg mirror "$mirror_url" '. + {"registry-mirrors": [$mirror]}' /etc/docker/daemon.json > "$tmp_file"
                        mv "$tmp_file" /etc/docker/daemon.json
                    else
                        # 为文件添加字段（简单但不完全健壮的方法）
                        # 检查文件是否为空或只有{}
                        if [ ! -s /etc/docker/daemon.json ] || [ "$(cat /etc/docker/daemon.json)" = "{}" ]; then
                            echo "{\"registry-mirrors\": [\"$mirror_url\"]}" > /etc/docker/daemon.json
                        else
                            # 在结束的}前添加
                            sed -i "s|}|\t\"registry-mirrors\": [\"$mirror_url\"]\n}|" /etc/docker/daemon.json
                        fi
                    fi
                fi
            else
                # 创建新文件
                echo "{\"registry-mirrors\": [\"$mirror_url\"]}" > /etc/docker/daemon.json
            fi
            
            # 重启Docker服务
            echo -e "${YELLOW}正在应用配置并重启Docker服务...${NC}"
            show_loading "正在重启Docker" 30
            systemctl restart docker
            echo -e "${GREEN}已配置Docker镜像加速并重启Docker服务${NC}"
            echo -e "${GREEN}镜像加速地址: ${mirror_url}${NC}"
            ;;
        2)
            # 删除镜像加速配置
            if [ -f "/etc/docker/daemon.json" ]; then
                # 创建备份
                cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)
                
                # 简单地创建一个空的配置文件
                echo '{}' > /etc/docker/daemon.json
                
                # 重启Docker服务
                echo -e "${YELLOW}正在重启Docker服务...${NC}"
                show_loading "等待Docker服务重启" 5
                
                if systemctl restart docker; then
                    echo -e "${GREEN}已删除镜像加速配置并重启Docker服务${NC}"
                else
                    echo -e "${RED}Docker服务重启失败，恢复备份...${NC}"
                    # 恢复最近的备份
                    cp "$(ls -t /etc/docker/daemon.json.bak.* | head -1)" /etc/docker/daemon.json
                    show_loading "正在恢复原配置" 3
                    systemctl restart docker
                    echo -e "${YELLOW}已恢复备份${NC}"
                fi
            else
                echo -e "${YELLOW}未发现镜像加速配置${NC}"
            fi
            ;;
        0) 
            # 返回上级菜单
            ;;
        *) 
            echo -e "${RED}无效的选择${NC}"
            ;;
    esac
    
    show_footer
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
            ufw route allow proto tcp from any to any port "$port"
            success_msg "已开放端口 $port 给所有公网IP"
            ;;
        2)
            read -p "请输入要开放的端口号: " port
            read -p "请输入指定的IP地址: " host_ip
            ufw route allow from "$host_ip" to any port "$port"
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
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} 🐳 Docker 容器信息${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════════════════════${NC}"
    
    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker 未安装${NC}"
        return
    fi
    if ! docker info &> /dev/null 2>&1; then
        echo -e "${RED}Docker 服务未运行${NC}"
        return 1
    fi

    # 获取容器数量
    local running=$(docker ps -q | wc -l)
    local total=$(docker ps -aq | wc -l)
    echo ""
    echo -e "${YELLOW}运行: ${GREEN}${running}${NC}  /  总计: ${WHITE}${total}${NC}"
    echo ""
    
    # 表头 - 增加间距
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────────────────${NC}"
    printf "${BOLD}%-18s  %-22s  %-4s  %-14s  %-14s  %-20s  %s${NC}\n" \
        "名称" "镜像" "状态" "CPU/内存" "IP" "端口" "运行时长"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────────────────${NC}"
    
    # 遍历每个运行的容器
    for cid in $(docker ps -q 2>/dev/null); do
        # 容器名称
        local name=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's/^\///' | cut -c1-18)
        
        # 镜像（简化，只取最后部分）
        local image=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null)
        # 去掉registry前缀，只保留镜像名:tag
        image=$(echo "$image" | sed 's|.*/||' | cut -c1-22)
        
        # 状态
        local state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)
        local state_icon="${GREEN}Up${NC}"
        [ "$state" != "running" ] && state_icon="${RED}Down${NC}"
        
        # CPU和内存
        local stats=$(docker stats "$cid" --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}" 2>/dev/null)
        local cpu=$(echo "$stats" | cut -d'|' -f1)
        local mem=$(echo "$stats" | cut -d'|' -f2 | cut -d'/' -f1 | xargs)
        local cpu_mem="${cpu}/${mem}"
        
        # IP地址
        local ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null)
        [ -z "$ip" ] && ip="-"
        
        # 端口映射 (格式: 宿主机端口->容器端口/协议)
        local ports_raw=$(docker port "$cid" 2>/dev/null)
        local port_display=""
        
        if [ -n "$ports_raw" ]; then
            # 有端口映射 - 显示所有端口
            while IFS= read -r line; do
                # line 格式: 1200/tcp -> 0.0.0.0:1200
                local container_port=$(echo "$line" | cut -d' ' -f1)  # 1200/tcp
                local host_port=$(echo "$line" | sed 's/.*://')       # 1200
                if [ -n "$port_display" ]; then
                    port_display="${port_display}, ${host_port}->${container_port}"
                else
                    port_display="${host_port}->${container_port}"
                fi
            done <<< "$ports_raw"
        else
            # 没有端口映射 - 检查是否有暴露的端口
            local exposed=$(docker inspect --format '{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' "$cid" 2>/dev/null | xargs)
            if [ -n "$exposed" ]; then
                port_display="${exposed} (未映射)"
            else
                port_display="-"
            fi
        fi
        
        # 运行时长
        local uptime=$(docker ps --filter "id=$cid" --format "{{.Status}}" 2>/dev/null | sed 's/Up //')
        [ -z "$uptime" ] && uptime="-"
        
        # 输出一行 - 增加列间距
        printf "%-18s  %-22s  ${state_icon}  %-14s  %-14s  %-20s  %s\n" \
            "$name" "$image" "$cpu_mem" "$ip" "$port_display" "$uptime"
    done
    
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────────────────${NC}"
    
    # 磁盘使用摘要
    echo ""
    local images_size=$(docker system df --format "{{.Size}}" 2>/dev/null | head -1)
    local containers_size=$(docker system df --format "{{.Size}}" 2>/dev/null | sed -n '2p')
    local volumes_size=$(docker system df --format "{{.Size}}" 2>/dev/null | sed -n '3p')
    echo -e "${BOLD}📊 磁盘:${NC} 镜像: ${images_size}  容器: ${containers_size}  卷: ${volumes_size}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════════════════════${NC}"
}

# 容器管理函数
manage_containers() {
    while true; do
        clear_screen
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD} 🐳 Docker 容器管理${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # 检查是否安装了 Docker
        if ! command -v docker &> /dev/null; then
            echo -e "${RED}Docker 未安装，无法管理容器${NC}"
            echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
            return 1
        fi
        
        # 检查 Docker 服务是否正常运行
        if ! docker info &> /dev/null; then
            echo -e "${RED}Docker 服务未正常运行${NC}"
            echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
            return 1
        fi
        
        # 容器统计
        local running=$(docker ps -q 2>/dev/null | wc -l)
        local stopped=$(docker ps -aq --filter "status=exited" 2>/dev/null | wc -l)
        local total=$(docker ps -aq 2>/dev/null | wc -l)
        echo -e " ${GREEN}● 运行中:${NC} ${running}   ${RED}● 已停止:${NC} ${stopped}   总计: ${total}"
        echo ""
        
        # 显示容器列表
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
        printf " ${BOLD}%-3s  %-22s  %-30s  %s${NC}\n" "#" "名称" "镜像" "状态"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
        
        container_count=0
        container_ids=()
        container_names=()
        
        while IFS='|' read -r id name image status; do
            if [ -n "$id" ]; then
                container_count=$((container_count + 1))
                container_ids+=("$id")
                container_names+=("$name")
                
                # 状态颜色
                local status_color="${GREEN}"
                [[ "$status" == *"Exited"* ]] && status_color="${RED}"
                [[ "$status" == *"Paused"* ]] && status_color="${YELLOW}"
                
                # 截断长名称和镜像名
                local short_name="${name:0:22}"
                local short_image="${image:0:30}"
                
                printf " %-3s  %-22s  %-30s  ${status_color}%s${NC}\n" \
                    "$container_count" "$short_name" "$short_image" "$status"
            fi
        done < <(docker ps -a --format "{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}")
        
        # 如果没有容器，显示提示
        if [ $container_count -eq 0 ]; then
            echo -e " ${YELLOW}当前没有任何容器${NC}"
        fi
        
        echo ""
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
        show_menu_item "1" "启动容器"
        show_menu_item "2" "停止容器"
        show_menu_item "3" "重启容器"
        show_menu_item "4" "暂停容器"
        show_menu_item "5" "恢复容器"
        show_menu_item "6" "删除容器"
        echo ""
        show_menu_item "0" "返回上级菜单"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-6]: "${NC})" choice
        
        case $choice in
            0) return ;;
            [1-6]) 
                if [ $container_count -eq 0 ]; then
                    echo -e "${YELLOW}当前没有容器可操作${NC}"
                    read -p "$(echo -e ${YELLOW}"按回车键继续..."${NC})"
                    continue
                fi
                
                # 选择目标容器
                echo -e ""
                echo -e "${BOLD} 请选择要操作的容器:${NC}"
                echo -e ""

                # 使用颜色交替显示容器
                for i in $(seq 0 $((container_count-1))); do
                    # 交替使用不同的颜色显示
                    if [ $((i % 2)) -eq 0 ]; then
                        echo -e "${GREEN}$((i+1))${NC}) ${container_names[$i]} (${container_ids[$i]:0:12})"
                    else
                        echo -e "${YELLOW}$((i+1))${NC}) ${container_names[$i]} (${container_ids[$i]:0:12})"
                    fi
                done

                echo -e ""
                echo -e "${RED}0${NC}) 取消操作"
                
                # 读取用户选择的容器
                read -p "$(echo -e ${YELLOW}"请输入容器序号 [0-$container_count]: "${NC})" container_choice
                
                # 检查用户输入是否有效
                if ! [[ "$container_choice" =~ ^[0-9]+$ ]] || [ "$container_choice" -lt 0 ] || [ "$container_choice" -gt $container_count ]; then
                    echo -e "${RED}无效的选择${NC}"
                elif [ "$container_choice" -eq 0 ]; then
                    # 用户取消操作
                    continue
                else
                    # 获取用户选择的容器ID
                    selected_idx=$((container_choice-1))
                    target_container="${container_ids[$selected_idx]}"
                    target_name="${container_names[$selected_idx]}"
                    
                    # 执行对应操作
                    case $choice in
                        1) # 启动容器
                            echo -e "${YELLOW}正在启动容器 ${target_name}...${NC}"
                            docker start "$target_container"
                            if [ $? -eq 0 ]; then
                                echo -e "${GREEN}容器已启动成功${NC}"
                            else
                                echo -e "${RED}容器启动失败${NC}"
                            fi
                            ;;
                        2) # 停止容器
                            echo -e "${YELLOW}正在停止容器 ${target_name}...${NC}"
                            docker stop "$target_container"
                            if [ $? -eq 0 ]; then
                                echo -e "${GREEN}容器已停止成功${NC}"
                            else
                                echo -e "${RED}容器停止失败${NC}"
                            fi
                            ;;
                        3) # 重启容器
                            echo -e "${YELLOW}正在重启容器 ${target_name}...${NC}"
                            docker restart "$target_container"
                            if [ $? -eq 0 ]; then
                                echo -e "${GREEN}容器已重启成功${NC}"
                            else
                                echo -e "${RED}容器重启失败${NC}"
                            fi
                            ;;
                        4) # 暂停容器
                            echo -e "${YELLOW}正在暂停容器 ${target_name}...${NC}"
                            docker pause "$target_container"
                            if [ $? -eq 0 ]; then
                                echo -e "${GREEN}容器已暂停成功${NC}"
                            else
                                echo -e "${RED}容器暂停失败${NC}"
                            fi
                            ;;
                        5) # 恢复容器
                            echo -e "${YELLOW}正在恢复容器 ${target_name}...${NC}"
                            docker unpause "$target_container"
                            if [ $? -eq 0 ]; then
                                echo -e "${GREEN}容器已恢复成功${NC}"
                            else
                                echo -e "${RED}容器恢复失败${NC}"
                            fi
                            ;;
                        6) # 删除容器
                            echo -e "${RED}警告: 此操作将删除容器 ${target_name}${NC}"
                            read -p "$(echo -e ${YELLOW}"确认删除吗? [y/N]: "${NC})" confirm
                            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                                echo -e "${YELLOW}正在删除容器...${NC}"
                                docker rm -f "$target_container"
                                if [ $? -eq 0 ]; then
                                    echo -e "${GREEN}容器已删除成功${NC}"
                                else
                                    echo -e "${RED}容器删除失败${NC}"
                                fi
                            else
                                echo -e "${YELLOW}已取消删除操作${NC}"
                            fi
                            ;;
                    esac
                fi
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                ;;
        esac
        
        read -p "$(echo -e ${YELLOW}"按回车键继续..."${NC})"
    done
}

# 删除未使用的 Docker 资源
clean_docker_resources() {
    echo -e "${BLUE}======= Docker 资源清理 ========${NC}"
    
    # 检查 Docker 是否可用
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker 未安装，无法清理资源${NC}"
        return 1
    fi

    # 显示清理前的空间情况
    echo -e "${YELLOW}清理前的 Docker 资源占用：${NC}"
    docker system df
    echo ""
    
    echo -e "${YELLOW}选择清理模式：${NC}"
    echo "1. 保守清理 (只清理悬空镜像和已停止容器)"
    echo "2. 标准清理 (清理所有未使用的镜像、容器、网络)"
    echo "3. 深度清理 (清理所有未使用资源，包括 volumes)"
    echo "0. 取消"
    
    read -p "选择清理模式 [0-3]: " clean_mode
    
    case $clean_mode in
        1)
            # 保守清理：只清理悬空镜像和已停止容器
            echo -e "\n${YELLOW}正在清理已停止的容器...${NC}"
            docker container prune -f
            
            echo -e "\n${YELLOW}正在清理悬空镜像...${NC}"
            docker image prune -f
            ;;
        2)
            # 标准清理：清理所有未使用的镜像（包括没有容器引用的）
            echo -e "\n${YELLOW}正在清理已停止的容器...${NC}"
            docker container prune -f
            
            echo -e "\n${YELLOW}正在清理所有未使用的镜像（包括旧版本镜像）...${NC}"
            docker image prune -a -f
            
            echo -e "\n${YELLOW}正在清理未使用的网络...${NC}"
            docker network prune -f
            
            echo -e "\n${YELLOW}正在清理构建缓存...${NC}"
            docker builder prune -f
            ;;
        3)
            # 深度清理：一键清理所有
            echo -e "${RED}警告：这将删除所有未使用的容器、网络、镜像和 volumes！${NC}"
            read -p "确认深度清理? (输入 YES 确认): " confirm
            if [ "$confirm" = "YES" ]; then
                echo -e "\n${YELLOW}正在执行深度清理...${NC}"
                docker system prune -a --volumes -f
            else
                echo -e "${YELLOW}已取消深度清理${NC}"
                return
            fi
            ;;
        0)
            echo -e "${YELLOW}已取消清理${NC}"
            return
            ;;
        *)
            echo -e "${RED}无效的选择${NC}"
            return 1
            ;;
    esac

    # 显示清理后的空间
    echo -e "\n${GREEN}Docker 资源清理完成！${NC}"
    echo -e "${YELLOW}清理后的 Docker 资源占用：${NC}"
    docker system df
}

# 显示 Docker 网络详细信息
show_docker_networks() {
    clear_screen
    show_header "Docker 网络详细信息"
    
    # 检查 Docker 是否可用
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker 未安装，无法显示网络信息${NC}"
        show_footer
        return 1
    fi

    # 列出所有网络
    echo -e "${BOLD} 网络列表${NC}"
    echo -e ""
    docker network ls 2>/dev/null
    
    # 显示每个网络的详细信息
    networks=$(docker network ls -q)
    
    if [ -n "$networks" ]; then
        for network in $networks; do
            echo -e ""
            echo -e "${YELLOW}网络详细信息${NC}"
            
            # 网络基本信息
            network_name=$(docker network inspect "$network" -f '{{.Name}}')
            network_driver=$(docker network inspect "$network" -f '{{.Driver}}')
            network_scope=$(docker network inspect "$network" -f '{{.Scope}}')
            
            echo -e " ${GREEN}网络名称:${NC} $network_name"
            echo -e " ${GREEN}网络驱动:${NC} $network_driver"
            echo -e " ${GREEN}网络范围:${NC} $network_scope"
            
            # IPAM配置
            subnet=$(docker network inspect "$network" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
            gateway=$(docker network inspect "$network" -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
            
            echo -e " ${GREEN}子网:${NC} $subnet"
            echo -e " ${GREEN}网关:${NC} $gateway"
            
            # 连接的容器
            echo -e ""
            echo -e "${YELLOW}已连接容器${NC}"
            containers=$(docker network inspect "$network" -f '{{range .Containers}}{{.Name}} {{end}}')
            
            if [[ -n "$containers" ]]; then
                for container in $containers; do
                    echo -e " • ${GREEN}$container${NC}"
                done
            else
                echo -e " ${RED}无容器连接到此网络${NC}"
            fi
            
            echo -e ""
            echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
        done
    else
        echo -e "${YELLOW}未找到任何 Docker 网络${NC}"
    fi
    
    show_footer
}

# 7. Swap 配置函数     
configure_swap() {
    clear_screen
    show_header "Swap 配置管理"
    
    # 显示当前 Swap 状态
    echo -e "${BOLD} 💾 当前 Swap 状态${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
    
    local swap_used=$(free -m 2>/dev/null | awk '/Swap:/ {print $3}')
    local swap_total=$(free -m 2>/dev/null | awk '/Swap:/ {print $2}')
    local swap_free=$(free -m 2>/dev/null | awk '/Swap:/ {print $4}')
    
    if [ -n "$swap_total" ] && [ "$swap_total" -gt 0 ]; then
        local swap_percent=$((swap_used * 100 / swap_total))
        echo -en " ${CYAN}使用率:${NC} "
        get_progress_bar "$swap_percent"
        echo ""
        echo -e " ${CYAN}已用:${NC} ${swap_used}MB   ${CYAN}空闲:${NC} ${swap_free}MB   ${CYAN}总计:${NC} ${swap_total}MB"
    else
        echo -e " ${YELLOW}未配置 Swap${NC}"
    fi
    
    echo ""
    echo -e "${BOLD} 📄 Swap 文件信息${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
    if [ -f /swapfile ]; then
        local swap_size=$(ls -lh /swapfile 2>/dev/null | awk '{print $5}')
        local swap_perm=$(ls -l /swapfile 2>/dev/null | awk '{print $1}')
        echo -e " ${CYAN}文件:${NC} /swapfile"
        echo -e " ${CYAN}大小:${NC} ${swap_size}"
        echo -e " ${CYAN}权限:${NC} ${swap_perm}"
    else
        echo -e " ${YELLOW}未检测到 Swap 文件${NC}"
    fi
    
    # Swappiness 值
    local swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    echo -e " ${CYAN}Swappiness:${NC} ${swappiness}"
    
    echo ""
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
    show_menu_item "1" "创建/调整 Swap"
    show_menu_item "2" "删除 Swap"
    show_menu_item "3" "调整 Swappiness"
    echo ""
    show_menu_item "0" "返回主菜单"
    
    show_footer
    
    read -p "$(echo -e ${YELLOW}"请选择操作 [0-3]: "${NC})" choice
    
    case $choice in
        1) create_swap ;;
        2) remove_swap ;;
        3) adjust_swappiness ;;
        0) return ;;
        *) echo -e "${RED}无效的选择${NC}" ;;
    esac
}

# 创建或调整 Swap
create_swap() {
    # 检查是否已存在 swap 文件
    if [ -f /swapfile ]; then
        echo -e "${YELLOW}检测到已存在 Swap 文件${NC}"
        
        # 检查swap是否真的在使用中
        is_swap_active=$(swapon -s | grep -c "/swapfile" || echo 0)
        
        read -p "是否要调整大小？(y/n): " adjust
        if [[ "$adjust" =~ ^[Yy]$ ]]; then
            if [ "$is_swap_active" -gt 0 ]; then
                echo "正在关闭已存在的swap..."
                swapoff /swapfile || {
                    echo -e "${YELLOW}警告: 无法正常关闭swap，尝试强制处理...${NC}"
                    # 尝试先删除旧文件
                    rm -f /swapfile || error_exit "无法删除现有 Swap 文件"
                }
            else
                echo -e "${YELLOW}检测到swap文件存在但未激活，将直接替换${NC}"
                # 直接删除，不尝试关闭
                rm -f /swapfile || error_exit "无法删除现有 Swap 文件"
            fi
        else
            return
        fi
    fi
    
    # 获取系统内存大小（以 GB 为单位）
    local mem_total=$(free -g | awk '/^Mem:/{print $2}')
    
    echo -e "\n${BLUE}推荐 Swap 大小：${NC}"
    echo "1) 内存小于 2GB：建议设置为内存的 2 倍"
    echo "2) 内存 2-8GB：建议设置为内存大小"
    echo "3) 内存大于 8GB：建议设置为 8GB 或根据需求调整"
    
    while true; do
        read -p "请输入要创建的 Swap 大小(GB): " swap_size
        if [[ "$swap_size" =~ ^[0-9]+$ ]] && [ "$swap_size" -gt 0 ]; then
            break
        fi
        echo -e "${RED}请输入有效的数字${NC}"
    done
    
    echo -e "${YELLOW}正在创建 Swap 文件，请稍候...${NC}"
    
    # 创建 swap 文件
    # dd if=/dev/zero of=/swapfile bs=1G count=$swap_size status=progress || error_exit "Swap 文件创建失败"
    
    # 使用较小的块大小，避免内存不足问题
    dd if=/dev/zero of=/swapfile bs=1M count=$(($swap_size * 1024)) status=progress || error_exit "Swap 文件创建失败"
    
    # 设置权限
    chmod 600 /swapfile || error_exit "无法设置 Swap 文件权限"
    
    # 格式化为 swap
    mkswap /swapfile || error_exit "Swap 格式化失败"
    
    # 启用 swap
    swapon /swapfile || error_exit "Swap 启用失败"
    
    # 添加到 fstab
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    
    echo -e "${GREEN}Swap 创建完成！当前状态：${NC}"
    free -h | grep -i swap
}

# 删除 Swap
remove_swap() {
    if [ ! -f /swapfile ]; then
        echo -e "${RED}未检测到 Swap 文件${NC}"
        return
    fi
    
    read -p "确定要删除 Swap 吗？(yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}操作已取消${NC}"
        return
    fi
    
    # 检查swap是否真的在使用中
    is_swap_active=$(swapon -s | grep -c "/swapfile" || echo 0)
    
    # 关闭 swap
    if [ "$is_swap_active" -gt 0 ]; then
        echo "正在关闭swap..."
        swapoff /swapfile || {
            echo -e "${YELLOW}警告: 无法正常关闭swap，将强制继续...${NC}"
        }
    else
        echo -e "${YELLOW}注意: Swap文件存在但未被激活${NC}"
    fi
    
    # 从 fstab 中删除
    sed -i '/\/swapfile/d' /etc/fstab
    
    # 删除文件
    rm -f /swapfile
    
    echo -e "${GREEN}Swap 已成功删除${NC}"
}

# 调整 Swappiness
adjust_swappiness() {
    local current_swappiness=$(cat /proc/sys/vm/swappiness)
    
    echo -e "${BLUE}当前 swappiness 值：${NC}$current_swappiness"
    echo -e "${YELLOW}推荐值：${NC}"
    echo "10-20: 桌面环境"
    echo "1-10: 服务器环境"
    echo "0: 仅在绝对必要时使用 swap"
    
    while true; do
        read -p "请输入新的 swappiness 值(0-100): " new_swappiness
        if [[ "$new_swappiness" =~ ^[0-9]+$ ]] && [ "$new_swappiness" -ge 0 ] && [ "$new_swappiness" -le 100 ]; then
            break
        fi
        echo -e "${RED}请输入0-100之间的数字${NC}"
    done
    
    # 立即生效
    sysctl vm.swappiness=$new_swappiness
    
    # 永久生效
    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo "vm.swappiness=$new_swappiness" >> /etc/sysctl.conf
    else
        sed -i "s/vm.swappiness=.*/vm.swappiness=$new_swappiness/" /etc/sysctl.conf
    fi
    
    echo -e "${GREEN}Swappiness 已设置为 $new_swappiness${NC}"
}

# 8. 1Panel安装
install_1panel() {
    read -p "是否安装1Panel? (y/n): " answer
    if [ "$answer" = "y" ]; then
        curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh -o quick_start.sh && bash quick_start.sh
    fi
}

# 9. v2ray-agent安装
install_v2ray_agent() {
    read -p "是否安装v2ray-agent? (y/n): " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        local script_file="/tmp/v2ray-agent-install.sh"
        
        echo -e "${BLUE}正在下载 v2ray-agent 安装脚本...${NC}"
        if ! wget -O "$script_file" https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh 2>/dev/null; then
            error_exit "v2ray-agent 脚本下载失败"
        fi
        
        if [ ! -s "$script_file" ]; then
            error_exit "下载的脚本文件为空"
        fi
        
        chmod 700 "$script_file"
        "$script_file"
        local exit_code=$?
        rm -f "$script_file"
        
        if [ $exit_code -ne 0 ]; then
            echo -e "${YELLOW}v2ray-agent 安装脚本退出码: $exit_code${NC}"
        fi
    fi
}

# 10.系统安全检查函数
system_security_check() {
    clear_screen
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} 🔒 系统安全检查${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 1. 系统信息
    echo -e "${BOLD} 📊 系统信息${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    local boot_time=$(who -b 2>/dev/null | awk '{print $3, $4}')
    local uptime_info=$(uptime -p 2>/dev/null | sed 's/up //')
    local kernel=$(uname -r 2>/dev/null)
    local user=$(whoami)
    echo -e " ${CYAN}启动时间:${NC} ${boot_time}   ${CYAN}运行时长:${NC} ${uptime_info}"
    echo -e " ${CYAN}内核版本:${NC} ${kernel}   ${CYAN}当前用户:${NC} ${user}"
    echo ""
    
    # 2. 关键端口
    echo -e "${BOLD} 🌐 关键端口监听${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    
    # 端口统计
    local tcp_ext=$(ss -tlnp 2>/dev/null | grep -E "0\.0\.0\.0:|:::" | grep -c LISTEN 2>/dev/null || echo "0")
    local tcp_loc=$(ss -tlnp 2>/dev/null | grep -v -E "0\.0\.0\.0:|:::" | grep -c LISTEN 2>/dev/null || echo "0")
    local udp_ext=$(ss -ulnp 2>/dev/null | grep -E "0\.0\.0\.0:|:::" | grep -v "State" | wc -l 2>/dev/null || echo "0")
    local udp_loc=$(ss -ulnp 2>/dev/null | grep -v -E "0\.0\.0\.0:|:::" | grep -v "State" | wc -l 2>/dev/null || echo "0")
    
    # UFW 实际放行检测
    local ufw_actual=""
    if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        local ufw_allowed=$(ufw status 2>/dev/null | grep -E "ALLOW" | grep -oE "^[0-9]+" | sort -u)
        local actual_count=0
        
        # 计算既在监听又在 UFW 放行的端口数
        for port in $(ss -tlnp 2>/dev/null | grep -E "0\.0\.0\.0:|:::" | grep LISTEN | awk '{print $4}' | rev | cut -d: -f1 | rev | sort -u); do
            if echo "$ufw_allowed" | grep -qx "$port"; then
                ((actual_count++))
            fi
        done
        ufw_actual="  ${CYAN}UFW实际:${NC} ${actual_count}"
    else
        ufw_actual="  ${DIM}(UFW未启用)${NC}"
    fi
    
    echo -e " ${CYAN}TCP:${NC} 对外 ${tcp_ext} | 本地 ${tcp_loc}    ${CYAN}UDP:${NC} 对外 ${udp_ext} | 本地 ${udp_loc}${ufw_actual}"
    
    # 关键服务状态
    local ssh_status=$(ss -tlnp 2>/dev/null | grep -qE ":22\s|sshd" && echo "${GREEN}●${NC}" || echo "${DIM}○${NC}")
    local http_status=$(ss -tlnp 2>/dev/null | grep -q ":80\s" && echo "${GREEN}●${NC}" || echo "${DIM}○${NC}")
    local https_status=$(ss -tlnp 2>/dev/null | grep -q ":443\s" && echo "${GREEN}●${NC}" || echo "${DIM}○${NC}")
    echo -e " ${CYAN}关键服务:${NC} SSH ${ssh_status}  HTTP ${http_status}  HTTPS ${https_status}"
    echo ""
    
    # 3. SSH 安全配置
    echo -e "${BOLD} 🔐 SSH 安全配置${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    if [ -f /etc/ssh/sshd_config ]; then
        local root_login=$(sshd -T 2>/dev/null | grep "permitrootlogin" | awk '{print $2}')
        local pwd_auth=$(sshd -T 2>/dev/null | grep "passwordauthentication" | awk '{print $2}')
        
        # Root登录状态
        local root_status="${GREEN}✓ 安全${NC}"
        [[ "$root_login" == "yes" ]] && root_status="${RED}✗ 危险${NC}"
        [[ "$root_login" == "without-password" ]] && root_status="${YELLOW}⚠ 仅密钥${NC}"
        
        # 密码认证状态
        local pwd_status="${GREEN}✓ 已禁用${NC}"
        [[ "$pwd_auth" == "yes" ]] && pwd_status="${YELLOW}⚠ 已启用${NC}"
        
        echo -e " ${CYAN}Root登录:${NC} ${root_status}   ${CYAN}密码认证:${NC} ${pwd_status}"
    else
        echo -e " ${RED}SSH 配置文件不存在${NC}"
    fi
    echo ""
    
    # 4. 防火墙状态
    echo -e "${BOLD} 🛡️ 防火墙状态${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    if command -v ufw &> /dev/null; then
        local ufw_status=$(ufw status 2>/dev/null | head -1)
        if echo "$ufw_status" | grep -q "active"; then
            local rule_count=$(ufw status 2>/dev/null | grep -c "ALLOW\|DENY" || echo "0")
            echo -e " ${GREEN}● UFW 已启用${NC}   规则数量: ${rule_count}"
        else
            echo -e " ${RED}● UFW 未启用${NC}"
        fi
    else
        echo -e " ${YELLOW}UFW 未安装${NC}"
    fi
    echo ""
    
    # 5. Fail2ban 状态
    echo -e "${BOLD} 🚫 Fail2ban 状态${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    if command -v fail2ban-client &> /dev/null; then
        local jail_count=$(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk '{print $NF}')
        local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2 | xargs)
        if [ -n "$jail_count" ] && [ "$jail_count" -gt 0 ]; then
            echo -e " ${GREEN}● 运行中${NC}   监狱数: ${jail_count}"
            echo -e " ${DIM}监狱: ${jails}${NC}"
        else
            echo -e " ${YELLOW}⚠ 无活动监狱${NC}"
        fi
    else
        echo -e " ${YELLOW}Fail2ban 未安装${NC}"
    fi
    echo ""
    
    # 6. 最近登录
    echo -e "${BOLD} 👤 最近登录${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    last -a 2>/dev/null | head -3 | while read -r line; do
        echo -e " ${DIM}${line}${NC}"
    done
    echo ""
    
    # 7. 安全建议
    echo -e "${BOLD} 💡 安全建议${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    echo -e " ${DIM}• 定期更新系统和软件包${NC}"
    echo -e " ${DIM}• 使用 SSH 密钥认证，禁用密码登录${NC}"
    echo -e " ${DIM}• 确保防火墙和 Fail2ban 正常运行${NC}"
    echo -e " ${DIM}• 监控异常登录活动${NC}"
    
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
}

# 11. 系统安全加固前的确认函数
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

# 12. 资源监控函数
system_resource_monitor() {
    clear_screen
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} 📊 系统资源监控${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # CPU信息
    echo -e "${BOLD} 💻 CPU 信息${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    local cpu_model=$(lscpu 2>/dev/null | grep "Model name" | cut -d':' -f2 | xargs)
    local cpu_cores=$(lscpu 2>/dev/null | grep "^CPU(s):" | cut -d':' -f2 | xargs)
    local cpu_threads=$(lscpu 2>/dev/null | grep "Thread(s) per core" | cut -d':' -f2 | xargs)
    echo -e " ${CYAN}型号:${NC} ${cpu_model}"
    echo -e " ${CYAN}核心:${NC} ${cpu_cores}   ${CYAN}线程/核:${NC} ${cpu_threads}"
    
    # CPU 使用率进度条
    local cpu_usage=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print int($2 + $4)}' || echo "0")
    [ -z "$cpu_usage" ] && cpu_usage=0
    echo -en " ${CYAN}使用率:${NC} "
    get_progress_bar "$cpu_usage"
    echo ""
    
    # CPU 负载
    local load=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | xargs)
    echo -e " ${CYAN}负载:${NC} ${load}"
    echo ""
    
    # 内存使用
    echo -e "${BOLD} 🧠 内存使用${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    local mem_used=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}')
    local mem_total=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')
    local mem_free=$(free -m 2>/dev/null | awk '/Mem:/ {print $4}')
    local mem_percent=0
    [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ] && mem_percent=$((mem_used * 100 / mem_total))
    
    echo -en " ${CYAN}使用率:${NC} "
    get_progress_bar "$mem_percent"
    echo ""
    echo -e " ${CYAN}已用:${NC} ${mem_used}MB   ${CYAN}空闲:${NC} ${mem_free}MB   ${CYAN}总计:${NC} ${mem_total}MB"
    
    # Swap
    local swap_used=$(free -m 2>/dev/null | awk '/Swap:/ {print $3}')
    local swap_total=$(free -m 2>/dev/null | awk '/Swap:/ {print $2}')
    local swap_percent=0
    [ -n "$swap_total" ] && [ "$swap_total" -gt 0 ] && swap_percent=$((swap_used * 100 / swap_total))
    echo -en " ${CYAN}Swap:${NC}   "
    if [ "$swap_total" -gt 0 ]; then
        get_progress_bar "$swap_percent"
        echo -e " ${DIM}${swap_used}/${swap_total}MB${NC}"
    else
        echo -e "${DIM}未配置${NC}"
    fi
    echo ""
    
    # 磁盘使用
    echo -e "${BOLD} 💾 磁盘使用${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    printf " ${BOLD}%-15s  %-10s  %-10s  %-10s  %-8s  %s${NC}\n" "挂载点" "总容量" "已用" "可用" "使用" "设备"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    
    df -h 2>/dev/null | grep -E "^/dev" | while read -r dev size used avail percent mount; do
        # 颜色根据使用率
        local pct=${percent%\%}
        local color="${GREEN}"
        [ "$pct" -ge 70 ] && color="${YELLOW}"
        [ "$pct" -ge 90 ] && color="${RED}"
        printf " %-15s  %-10s  %-10s  %-10s  ${color}%-8s${NC}  %s\n" "$mount" "$size" "$used" "$avail" "$percent" "$dev"
    done
    echo ""
    
    # 网络信息
    echo -e "${BOLD} 🌐 网络信息${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    local ipv4=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -1)
    local gateway=$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -1)
    echo -e " ${CYAN}IPv4:${NC} ${ipv4:-未检测到}   ${CYAN}网关:${NC} ${gateway:-未检测到}"
    
    # 运行时间
    local uptime_info=$(uptime -p 2>/dev/null | sed 's/up //')
    echo -e " ${CYAN}运行时间:${NC} ${uptime_info}"
    
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
}

# 13. 网络设置相关函数
# 13-1 DNS修改函数
modify_dns() {
    clear_screen
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} 🌐 DNS 修改${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 当前DNS
    local current_dns=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | head -2 | tr '\n' ' ')
    echo -e " ${CYAN}当前DNS:${NC} ${current_dns:-未配置}"
    echo ""
    
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    show_menu_item "1" "Google DNS (8.8.8.8, 8.8.4.4)"
    show_menu_item "2" "Cloudflare DNS (1.1.1.1, 1.0.0.1)"
    show_menu_item "3" "阿里DNS (223.5.5.5, 223.6.6.6)"
    show_menu_item "4" "自定义DNS"
    echo ""
    show_menu_item "0" "返回"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    
    read -p "$(echo -e ${YELLOW}"请选择 [0-4]: "${NC})" choice
    
    case $choice in
        1) 
            echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
            echo "nameserver 8.8.4.4" | sudo tee -a /etc/resolv.conf > /dev/null
            echo -e "${GREEN}✓ 已设置为 Google DNS${NC}"
            ;;
        2) 
            echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null
            echo "nameserver 1.0.0.1" | sudo tee -a /etc/resolv.conf > /dev/null
            echo -e "${GREEN}✓ 已设置为 Cloudflare DNS${NC}"
            ;;
        3) 
            echo "nameserver 223.5.5.5" | sudo tee /etc/resolv.conf > /dev/null
            echo "nameserver 223.6.6.6" | sudo tee -a /etc/resolv.conf > /dev/null
            echo -e "${GREEN}✓ 已设置为阿里DNS${NC}"
            ;;
        4)
            read -p "$(echo -e ${YELLOW}"请输入主DNS: "${NC})" primary_dns
            read -p "$(echo -e ${YELLOW}"请输入备用DNS(可留空): "${NC})" secondary_dns
            
            echo "nameserver $primary_dns" | sudo tee /etc/resolv.conf > /dev/null
            if [ -n "$secondary_dns" ]; then
                echo "nameserver $secondary_dns" | sudo tee -a /etc/resolv.conf > /dev/null
            fi
            echo -e "${GREEN}✓ DNS设置已更新${NC}"
            ;;
        0) return ;;
        *) echo -e "${RED}无效的选择${NC}" ;;
    esac
}

# 13-2 系统时区修改函数
modify_timezone() {
    clear_screen
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} 🕐 系统时区修改${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 当前时区
    local current_tz=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')
    local current_time=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e " ${CYAN}当前时区:${NC} ${current_tz:-未知}   ${CYAN}当前时间:${NC} ${current_time}"
    echo ""
    
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    show_menu_item "1" "亚洲/上海 (Asia/Shanghai)"
    show_menu_item "2" "亚洲/香港 (Asia/Hong_Kong)"
    show_menu_item "3" "亚洲/东京 (Asia/Tokyo)"
    show_menu_item "4" "美国/洛杉矶 (America/Los_Angeles)"
    show_menu_item "5" "美国/纽约 (America/New_York)"
    show_menu_item "6" "欧洲/伦敦 (Europe/London)"
    show_menu_item "7" "自定义时区"
    echo ""
    show_menu_item "0" "返回"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    
    read -p "$(echo -e ${YELLOW}"请选择 [0-7]: "${NC})" choice
    
    case $choice in
        1) sudo timedatectl set-timezone Asia/Shanghai ;;
        2) sudo timedatectl set-timezone Asia/Hong_Kong ;;
        3) sudo timedatectl set-timezone Asia/Tokyo ;;
        4) sudo timedatectl set-timezone America/Los_Angeles ;;
        5) sudo timedatectl set-timezone America/New_York ;;
        6) sudo timedatectl set-timezone Europe/London ;;
        7)
            echo -e "${YELLOW}可用时区列表:${NC}"
            timedatectl list-timezones | less
            read -p "$(echo -e ${YELLOW}"请输入时区名称: "${NC})" custom_timezone
            sudo timedatectl set-timezone "$custom_timezone"
            ;;
        0) return ;;
        *) echo -e "${RED}无效的选择${NC}" ;;
    esac
    
    echo -e "${GREEN}✓ 时区已更新为: $(timedatectl | grep 'Time zone' | awk '{print $3}')${NC}"
}


# 13-3 网络诊断函数
network_diagnostic() {
    clear_screen
    show_header "网络诊断"
    
    # 公网连接测试
    echo -e "${BOLD} 公网连接测试${NC}"
    echo -e ""
    while IFS= read -r line; do
        echo -e "$line"
    done < <(ping -c 4 8.8.8.8)
    
    # DNS解析测试
    echo -e ""
    echo -e "${BOLD} DNS 解析测试${NC}"
    echo -e ""
    while IFS= read -r line; do
        echo -e "$line"
    done < <(dig google.com +short)
    
    # 路由追踪
    echo -e ""
    echo -e "${BOLD} 路由追踪${NC}"
    echo -e ""
    while IFS= read -r line; do
        echo -e "$line"
    done < <(traceroute -n google.com | head -n 5)
    
    # 网络接口
    echo -e ""
    echo -e "${BOLD} 网络接口信息${NC}"
    echo -e ""
    while IFS= read -r line; do
        echo -e "$line"
    done < <(ip addr | grep -E "^[0-9]:|inet")
    
    show_footer
}

# 13-4 IPv6设置函数
ipv6_settings() {
    clear_screen
    show_header "IPv6设置"
    
    # 检查当前IPv6状态
    ipv6_disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)
    if [ "$ipv6_disabled" == "1" ]; then
        current_status="IPv6当前状态: 已禁用"
        option_text="启用IPv6"
    else
        current_status="IPv6当前状态: 已启用"
        option_text="禁用IPv6"
    fi
    
    echo -e ""
    echo -e " ${YELLOW}${current_status}${NC}"
    echo -e ""
    echo -e "${BOLD} IPv6选项${NC}"
    echo -e ""
    show_menu_item "1" "${option_text}"
    show_menu_item "0" "返回上级菜单"
    
    show_footer
    
    read -p "$(echo -e ${YELLOW}"请选择操作 [0-1]: "${NC})" choice
    
    case $choice in
        1)
            if [ "$ipv6_disabled" == "1" ]; then
                # 启用IPv6
                echo "0" | sudo tee /proc/sys/net/ipv6/conf/all/disable_ipv6 > /dev/null
                echo "0" | sudo tee /proc/sys/net/ipv6/conf/default/disable_ipv6 > /dev/null
                
                # 永久修改
                if [ -f /etc/sysctl.conf ]; then
                    sudo sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
                    sudo sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
                    echo "net.ipv6.conf.all.disable_ipv6 = 0" | sudo tee -a /etc/sysctl.conf > /dev/null
                    echo "net.ipv6.conf.default.disable_ipv6 = 0" | sudo tee -a /etc/sysctl.conf > /dev/null
                    sudo sysctl -p > /dev/null
                fi
                
                echo -e "${GREEN}IPv6已成功启用${NC}"
            else
                # 禁用IPv6
                echo "1" | sudo tee /proc/sys/net/ipv6/conf/all/disable_ipv6 > /dev/null
                echo "1" | sudo tee /proc/sys/net/ipv6/conf/default/disable_ipv6 > /dev/null
                
                # 永久修改
                if [ -f /etc/sysctl.conf ]; then
                    sudo sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
                    sudo sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
                    echo "net.ipv6.conf.all.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
                    echo "net.ipv6.conf.default.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
                    sudo sysctl -p > /dev/null
                fi
                
                echo -e "${GREEN}IPv6已成功禁用${NC}"
            fi
            ;;
        0) return ;;
        *) echo -e "${RED}无效的选择${NC}" ;;
    esac
}

# 13-6 BBR 加速设置
bbr_settings() {
    clear_screen
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} 🚀 BBR 加速设置${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 检查当前拥塞控制算法
    local current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local qdisc=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
    local kernel_ver=$(uname -r)
    
    # BBR状态
    local bbr_status="${RED}● 未启用${NC}"
    [ "$current_cc" == "bbr" ] && bbr_status="${GREEN}● 已启用${NC}"
    
    echo -e " ${CYAN}BBR状态:${NC} ${bbr_status}"
    echo -e " ${CYAN}拥塞控制:${NC} ${current_cc:-未知}   ${CYAN}队列:${NC} ${qdisc:-未知}   ${CYAN}内核:${NC} ${kernel_ver}"
    
    # 检查内核版本是否支持 BBR (需要 4.9+)
    local kernel_major=$(echo "$kernel_ver" | cut -d. -f1)
    local kernel_minor=$(echo "$kernel_ver" | cut -d. -f2)
    
    if [ "$kernel_major" -lt 4 ] || ([ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -lt 9 ]); then
        echo ""
        echo -e " ${RED}⚠️ 警告: 内核版本低于 4.9，可能不支持 BBR${NC}"
    fi
    echo ""
    
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
    if [ "$current_cc" == "bbr" ]; then
        show_menu_item "1" "禁用 BBR (切换回 cubic)"
    else
        show_menu_item "1" "启用 BBR 加速"
    fi
    show_menu_item "2" "查看当前网络参数"
    echo ""
    show_menu_item "0" "返回上级菜单"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    
    read -p "$(echo -e ${YELLOW}"请选择操作 [0-2]: "${NC})" choice
    
    case $choice in
        1)
            if [ "$current_cc" == "bbr" ]; then
                echo -e "${YELLOW}正在禁用 BBR...${NC}"
                sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
                sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
                echo "net.ipv4.tcp_congestion_control = cubic" >> /etc/sysctl.conf
                sysctl -p > /dev/null 2>&1
                echo -e "${GREEN}✓ BBR 已禁用，已切换回 cubic${NC}"
            else
                echo -e "${YELLOW}正在启用 BBR 加速...${NC}"
                cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)
                sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
                sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
                echo "# BBR 加速设置" >> /etc/sysctl.conf
                echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
                echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
                if sysctl -p > /dev/null 2>&1; then
                    local new_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
                    if [ "$new_cc" == "bbr" ]; then
                        echo -e "${GREEN}✓ BBR 加速已成功启用！${NC}"
                    else
                        echo -e "${RED}BBR 启用失败，可能内核不支持${NC}"
                    fi
                else
                    echo -e "${RED}配置应用失败${NC}"
                fi
            fi
            ;;
        2)
            echo ""
            echo -e "${BOLD} 当前网络参数${NC}"
            echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
            echo -e " ${CYAN}tcp_congestion_control:${NC} $(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')"
            echo -e " ${CYAN}default_qdisc:${NC} $(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')"
            echo -e " ${CYAN}tcp_fastopen:${NC} $(sysctl net.ipv4.tcp_fastopen 2>/dev/null | awk '{print $3}')"
            echo -e " ${CYAN}tcp_slow_start_after_idle:${NC} $(sysctl net.ipv4.tcp_slow_start_after_idle 2>/dev/null | awk '{print $3}')"
            ;;
        0) return ;;
        *) echo -e "${RED}无效的选择${NC}" ;;
    esac
}

# 13-5 主机名和hosts文件管理菜单
hostname_hosts_menu() {
    while true; do
        clear_screen
        show_header "主机名和hosts文件管理"
        
        # 显示当前主机名
        current_hostname=$(hostname)
        echo -e " ${YELLOW}当前主机名: ${WHITE}${current_hostname}${NC}"
        echo -e ""
        
        echo -e "${BOLD} 管理选项${NC}"
        echo -e ""
        show_menu_item "1" "修改系统主机名"
        show_menu_item "2" "编辑hosts文件"
        show_menu_item "3" "查看当前hosts文件"
        show_menu_item "0" "返回上级菜单"
        
        show_footer
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-3]: "${NC})" choice
        
        case $choice in
            1) modify_hostname ;;
            2) edit_hosts_file ;;
            3) view_hosts_file ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        [ "$choice" != "0" ] && read -p "$(echo -e ${YELLOW}"按回车键继续..."${NC})"
    done
}

# 修改系统主机名
modify_hostname() {
    clear_screen
    show_header "修改系统主机名"
    
    current_hostname=$(hostname)
    echo -e " ${YELLOW}当前主机名: ${WHITE}${current_hostname}${NC}"
    echo -e ""
    echo -e " ${YELLOW}请输入新的主机名:${NC}"
    echo -e ""
    
    read -p "$(echo -e ${YELLOW}"新主机名: "${NC})" new_hostname
    
    if [ -z "$new_hostname" ]; then
        echo -e "${RED}主机名不能为空${NC}"
        return
    fi
    
    # 检查主机名是否合法（只允许字母、数字、连字符）
    if ! [[ "$new_hostname" =~ ^[a-zA-Z0-9-]+$ ]]; then
        echo -e "${RED}主机名只能包含字母、数字和连字符${NC}"
        return
    fi
    
    # 修改主机名
    echo -e "${YELLOW}正在修改主机名...${NC}"
    
    # 对于使用hostnamectl的系统（systemd）
    if command -v hostnamectl &> /dev/null; then
        sudo hostnamectl set-hostname "$new_hostname"
    else
        # 传统方式设置主机名
        sudo hostname "$new_hostname"
        
        # 永久保存主机名
        if [ -f /etc/hostname ]; then
            echo "$new_hostname" | sudo tee /etc/hostname > /dev/null
        fi
    fi
    
    # 更新/etc/hosts文件中的主机名
    if [ -f /etc/hosts ]; then
        # 备份hosts文件
        sudo cp /etc/hosts /etc/hosts.bak
        
        # 更新localhost行中的主机名
        sudo sed -i "s/127.0.1.1.*$current_hostname/127.0.1.1\t$new_hostname/g" /etc/hosts
        
        echo -e "${GREEN}已在/etc/hosts文件中更新主机名${NC}"
    fi
    
    echo -e "${GREEN}主机名已成功修改为: ${new_hostname}${NC}"
    echo -e "${YELLOW}注意: 某些服务可能需要重启才能识别新的主机名${NC}"
}

# 编辑hosts文件
edit_hosts_file() {
    clear_screen
    show_header "编辑hosts文件"
    
    echo -e " ${YELLOW}添加自定义域名映射到hosts文件${NC}"
    echo -e ""
    echo -e " ${WHITE}格式: IP地址 域名${NC}"
    echo -e " ${WHITE}例如: 192.168.1.100 myserver.local${NC}"
    echo -e ""
    
    read -p "$(echo -e ${YELLOW}"IP地址: "${NC})" ip_address
    
    # 验证IP地址格式
    if ! [[ "$ip_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}无效的IP地址格式${NC}"
        return
    fi
    
    read -p "$(echo -e ${YELLOW}"域名: "${NC})" domain_name
    
    # 验证域名格式
    if [ -z "$domain_name" ]; then
        echo -e "${RED}域名不能为空${NC}"
        return
    fi
    
    # 检查是否已存在相同映射
    if grep -q "^$ip_address[[:space:]]*$domain_name" /etc/hosts; then
        echo -e "${YELLOW}警告: 该映射已存在于hosts文件中${NC}"
        read -p "$(echo -e ${YELLOW}"是否仍然添加? (y/n): "${NC})" confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${YELLOW}操作已取消${NC}"
            return
        fi
    fi
    
    # 备份hosts文件
    sudo cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d%H%M%S)
    
    # 添加新映射到hosts文件
    echo "$ip_address $domain_name" | sudo tee -a /etc/hosts > /dev/null
    
    echo -e "${GREEN}已成功添加映射: ${ip_address} → ${domain_name}${NC}"
    echo -e "${GREEN}hosts文件已备份为: /etc/hosts.bak.$(date +%Y%m%d%H%M%S)${NC}"
}

# 查看hosts文件内容
view_hosts_file() {
    clear_screen
    show_header "当前hosts文件内容"
    
    echo -e ""
    cat /etc/hosts | while IFS= read -r line; do
        echo -e "$line"
    done
    echo -e ""
    
    # 添加选项删除特定映射
    echo -e "${BOLD} 操作选项${NC}"
    echo -e ""
    show_menu_item "1" "删除hosts文件中的映射"
    show_menu_item "0" "返回上级菜单"
    
    read -p "$(echo -e ${YELLOW}"请选择操作 [0-1]: "${NC})" choice
    
    case $choice in
        1)
            read -p "$(echo -e ${YELLOW}"请输入要删除的域名: "${NC})" domain_to_delete
            if [ -z "$domain_to_delete" ]; then
                echo -e "${RED}域名不能为空${NC}"
                return
            fi
            
            # 备份hosts文件
            sudo cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d%H%M%S)
            
            # 删除包含该域名的行
            sudo sed -i "/[[:space:]]$domain_to_delete[[:space:]]*$/d" /etc/hosts
            
            echo -e "${GREEN}已删除域名 ${domain_to_delete} 的映射${NC}"
            ;;
        0) return ;;
        *) echo -e "${RED}无效的选择${NC}" ;;
    esac
}

# 14. 端口扫描检测
port_scan_detection() {
    clear_screen
    show_header "端口扫描检测 - 安全审计"
    
    echo -e "${BOLD} 🔍 系统开放端口检测${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    # 创建临时文件
    local tcp_file=$(mktemp)
    local udp_file=$(mktemp)
    
    # 收集 TCP 端口
    if command -v ss &> /dev/null; then
        ss -tlnp 2>/dev/null | grep LISTEN | while read -r line; do
            local addr=$(echo "$line" | awk '{print $4}')
            local port=$(echo "$addr" | rev | cut -d: -f1 | rev)
            local bind_addr=$(echo "$addr" | rev | cut -d: -f2- | rev)
            local process=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' | head -1)
            
            local scope_type=""
            if [[ "$bind_addr" == "0.0.0.0" ]] || [[ "$bind_addr" == "*" ]] || [[ "$bind_addr" == "[::]" ]]; then
                scope_type="external"
            elif [[ "$bind_addr" == "127.0.0.1" ]] || [[ "$bind_addr" == "::1" ]]; then
                scope_type="local"
            else
                scope_type="internal"
            fi
            
            echo "${port}|${scope_type}|${process:-未知}" >> "$tcp_file"
        done
        
        # 收集 UDP 端口
        ss -ulnp 2>/dev/null | grep -v "State" | while read -r line; do
            local addr=$(echo "$line" | awk '{print $4}')
            local port=$(echo "$addr" | rev | cut -d: -f1 | rev)
            local bind_addr=$(echo "$addr" | rev | cut -d: -f2- | rev)
            local process=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' | head -1)
            
            [[ -z "$port" ]] && continue
            
            local scope_type=""
            if [[ "$bind_addr" == "0.0.0.0" ]] || [[ "$bind_addr" == "*" ]]; then
                scope_type="external"
            else
                scope_type="local"
            fi
            
            echo "${port}|${scope_type}|${process:-未知}" >> "$udp_file"
        done
    fi
    
    # 去重并排序
    local tcp_sorted=$(mktemp)
    local udp_sorted=$(mktemp)
    sort -u "$tcp_file" | sort -t'|' -k1 -n > "$tcp_sorted"
    sort -u "$udp_file" | sort -t'|' -k1 -n > "$udp_sorted"
    
    # 统计
    local tcp_count=$(wc -l < "$tcp_sorted" 2>/dev/null || echo "0")
    local udp_count=$(wc -l < "$udp_sorted" 2>/dev/null || echo "0")
    local tcp_external=$(grep -c '|external|' "$tcp_sorted" 2>/dev/null || echo "0")
    local udp_external=$(grep -c '|external|' "$udp_sorted" 2>/dev/null || echo "0")
    
    # 显示表头
    echo -e "${YELLOW}【TCP 监听端口】${NC}\t\t\t\t${YELLOW}【UDP 监听端口】${NC}"
    echo -e "${DIM}端口\t\t状态\t服务${NC}\t\t\t${DIM}端口\t\t状态\t服务${NC}"
    echo -e "${BLUE}────────────────────────────────────\t────────────────────────────────────${NC}"
    
    # 获取最大行数
    local max_lines=$tcp_count
    [ "$udp_count" -gt "$max_lines" ] && max_lines=$udp_count
    
    # 读取到数组
    mapfile -t tcp_lines < "$tcp_sorted"
    mapfile -t udp_lines < "$udp_sorted"
    
    # 格式化状态显示
    get_scope_display() {
        local scope_type="$1"
        case "$scope_type" in
            "external") echo -e "\033[0;31m[对外]\033[0m" ;;
            "local")    echo -e "\033[0;32m[本地]\033[0m" ;;
            "internal") echo -e "\033[1;33m[内网]\033[0m" ;;
        esac
    }
    
    # 并排显示
    for ((i=0; i<max_lines; i++)); do
        local tcp_line="${tcp_lines[$i]:-}"
        local udp_line="${udp_lines[$i]:-}"
        
        # TCP 列
        if [ -n "$tcp_line" ]; then
            IFS='|' read -r port scope_type process <<< "$tcp_line"
            local scope_display=$(get_scope_display "$scope_type")
            printf " %-8s\t%b\t%-12s" "$port" "$scope_display" "${process:0:12}"
        else
            printf " %-8s\t%-6s\t%-12s" "" "" ""
        fi
        
        printf "\t"
        
        # UDP 列
        if [ -n "$udp_line" ]; then
            IFS='|' read -r port scope_type process <<< "$udp_line"
            local scope_display=$(get_scope_display "$scope_type")
            printf " %-8s\t%b\t%-12s" "$port" "$scope_display" "${process:0:12}"
        fi
        
        echo ""
    done
    
    echo ""
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────${NC}"
    
    # 统计信息
    echo -e "${BOLD} 📊 统计信息${NC}"
    echo -e " TCP: ${CYAN}${tcp_count}${NC} 个端口 (对外: ${RED}${tcp_external}${NC})    UDP: ${CYAN}${udp_count}${NC} 个端口 (对外: ${RED}${udp_external}${NC})"
    
    local total_external=$((tcp_external + udp_external))
    echo ""
    echo -e "${YELLOW}【安全建议】${NC}"
    echo -e " ${DIM}注: 以上仅显示系统监听状态，实际是否对外取决于 UFW 防火墙规则${NC}"
    if [ "$total_external" -gt 20 ]; then
        echo -e " ${YELLOW}⚠ 监听端口较多 (${total_external}个)，建议检查服务是否必要${NC}"
    else
        echo -e " ${GREEN}✓ 监听端口数量正常${NC}"
    fi
    
    # 常见危险端口检测
    echo ""
    echo -e "${YELLOW}【常见危险端口检测】${NC}"
    local dangerous_ports=("21:FTP" "23:Telnet" "3306:MySQL" "5432:PostgreSQL" "6379:Redis" "27017:MongoDB" "11211:Memcached")
    local found_dangerous=0
    
    for dp in "${dangerous_ports[@]}"; do
        local port="${dp%%:*}"
        local service="${dp##*:}"
        if grep -q "^${port}|external|" "$tcp_sorted" 2>/dev/null || grep -q "^${port}|external|" "$udp_sorted" 2>/dev/null; then
            echo -e " ${RED}⚠ 端口 $port ($service) 对外开放${NC}"
            found_dangerous=1
        fi
    done
    
    if [ "$found_dangerous" -eq 0 ]; then
        echo -e " ${GREEN}✓ 未发现常见危险端口对外开放${NC}"
    fi
    
    # 结合 UFW 检测真正对外开放的端口
    echo ""
    echo -e "${YELLOW}【UFW 放行端口检测】${NC}"
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        # 获取 UFW 允许的端口
        local ufw_allowed=$(ufw status | grep -E "ALLOW" | grep -oE "^[0-9]+(/tcp|/udp)?" | sort -u)
        local truly_open=0
        local truly_open_list=""
        
        # 检查哪些监听端口在 UFW 中放行
        while IFS='|' read -r port scope_type process; do
            [ -z "$port" ] && continue
            [ "$scope_type" != "external" ] && continue
            
            # 检查是否在 UFW 中放行
            if echo "$ufw_allowed" | grep -qE "^${port}(/tcp)?$"; then
                truly_open_list="${truly_open_list} ${port}/tcp"
                ((truly_open++))
            fi
        done < "$tcp_sorted"
        
        while IFS='|' read -r port scope_type process; do
            [ -z "$port" ] && continue
            [ "$scope_type" != "external" ] && continue
            
            if echo "$ufw_allowed" | grep -qE "^${port}(/udp)?$"; then
                truly_open_list="${truly_open_list} ${port}/udp"
                ((truly_open++))
            fi
        done < "$udp_sorted"
        
        if [ "$truly_open" -gt 0 ]; then
            echo -e " ${RED}真正对外开放: ${truly_open} 个端口${NC}"
            echo -e " ${DIM}$(echo $truly_open_list | tr ' ' '\n' | sort -u | tr '\n' ' ')${NC}"
        else
            echo -e " ${GREEN}✓ 没有监听端口在 UFW 中放行 (或使用默认策略)${NC}"
        fi
    else
        echo -e " ${DIM}UFW 未启用，无法检测${NC}"
    fi
    
    # 清理临时文件
    rm -f "$tcp_file" "$udp_file" "$tcp_sorted" "$udp_sorted"
    
    show_footer
}

# 15. 脚本自更新
GITHUB_REPO="li88iioo/init_server"  # 请替换为你的 GitHub 仓库地址
SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/init_server.sh"

check_script_update() {
    clear_screen
    show_header "脚本更新检查"
    
    echo -e "${BOLD} 📦 当前版本: ${CYAN}v${VERSION}${NC}"
    echo ""
    
    # 检查网络连接
    echo -e "${YELLOW}正在检查网络连接...${NC}"
    if ! ping -c 1 -W 3 github.com &>/dev/null && ! ping -c 1 -W 3 raw.githubusercontent.com &>/dev/null; then
        echo -e "${RED}无法连接到 GitHub，请检查网络连接${NC}"
        show_footer
        return 1
    fi
    echo -e "${GREEN}网络连接正常${NC}"
    echo ""
    
    # 获取远程版本
    echo -e "${YELLOW}正在获取最新版本信息...${NC}"
    local remote_version=""
    
    # 尝试获取远程脚本的版本号
    remote_version=$(curl -sL --connect-timeout 10 "$SCRIPT_URL" 2>/dev/null | grep -m1 '^VERSION=' | cut -d'"' -f2)
    
    if [ -z "$remote_version" ]; then
        echo -e "${YELLOW}无法获取远程版本信息${NC}"
        echo -e "${DIM}可能原因: 仓库未配置或网络问题${NC}"
        echo ""
        echo -e "${CYAN}如需配置自动更新，请修改脚本中的 GITHUB_REPO 变量${NC}"
        echo -e "${DIM}当前配置: ${GITHUB_REPO}${NC}"
        show_footer
        return 1
    fi
    
    echo -e "${BOLD} 🌐 最新版本: ${CYAN}v${remote_version}${NC}"
    echo ""
    
    # 版本比较
    if [ "$VERSION" = "$remote_version" ]; then
        echo -e "${GREEN}✓ 当前已是最新版本${NC}"
        show_footer
        return 0
    fi
    
    # 简单版本比较 (假设版本号格式为 x.y.z)
    local current_num=$(echo "$VERSION" | tr -d '.')
    local remote_num=$(echo "$remote_version" | tr -d '.')
    
    if [ "$remote_num" -gt "$current_num" ] 2>/dev/null; then
        echo -e "${YELLOW}发现新版本！${NC}"
        echo ""
        read -p "是否更新到 v${remote_version}? (y/n): " update_choice
        
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}正在下载更新...${NC}"
            
            # 获取当前脚本路径
            local script_path=$(readlink -f "$0")
            local backup_path="${script_path}.bak.$(date +%Y%m%d%H%M%S)"
            
            # 备份当前脚本
            cp "$script_path" "$backup_path"
            echo -e "${GREEN}已备份当前脚本到: ${backup_path}${NC}"
            
            # 下载新版本
            if curl -sL --connect-timeout 30 "$SCRIPT_URL" -o "${script_path}.new"; then
                # 验证下载的文件
                if head -1 "${script_path}.new" | grep -q "^#!/bin/bash"; then
                    mv "${script_path}.new" "$script_path"
                    chmod +x "$script_path"
                    echo -e "${GREEN}✓ 更新成功！${NC}"
                    echo -e "${YELLOW}请重新运行脚本以使用新版本${NC}"
                    exit 0
                else
                    echo -e "${RED}下载的文件无效，更新失败${NC}"
                    rm -f "${script_path}.new"
                fi
            else
                echo -e "${RED}下载失败，请检查网络连接${NC}"
            fi
        else
            echo -e "${YELLOW}已取消更新${NC}"
        fi
    else
        echo -e "${CYAN}当前版本较新或相同${NC}"
    fi
    
    show_footer
}

# 16. Docker 镜像源自动检测
test_docker_mirrors() {
    clear_screen
    show_header "Docker 镜像源自动检测"
    
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker 未安装${NC}"
        show_footer
        return 1
    fi
    
    echo -e "${BOLD} 🚀 正在测试镜像源速度...${NC}"
    echo -e "${DIM}这可能需要几分钟时间${NC}"
    echo ""
    
    # 常用镜像源列表
    local mirrors=(
        "https://docker.1ms.run"
        "https://docker.xuanyuan.me"
        "https://docker.m.daocloud.io"
        "https://dockerhub.icu"
        "https://hub.rat.dev"
        "https://docker.nastool.de"
        "https://docker.rainbond.cc"
        "https://registry.dockermirror.com"
    )
    
    local best_mirror=""
    local best_time=99999
    local results=()
    
    echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"
    printf " %-45s  %s\n" "镜像源" "延迟"
    echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"
    
    for mirror in "${mirrors[@]}"; do
        # 提取域名
        local domain=$(echo "$mirror" | sed 's|https://||' | cut -d/ -f1)
        
        # 测试连接延迟
        local start_time=$(date +%s%N)
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$mirror/v2/" 2>/dev/null)
        local end_time=$(date +%s%N)
        
        if [ "$http_code" = "200" ] || [ "$http_code" = "401" ]; then
            local elapsed=$(( (end_time - start_time) / 1000000 ))
            results+=("$elapsed:$mirror")
            
            if [ "$elapsed" -lt "$best_time" ]; then
                best_time=$elapsed
                best_mirror=$mirror
            fi
            
            printf " %-45s  ${GREEN}%dms${NC}\n" "$mirror" "$elapsed"
        else
            printf " %-45s  ${RED}不可用${NC}\n" "$mirror"
        fi
    done
    
    echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"
    echo ""
    
    if [ -n "$best_mirror" ]; then
        echo -e "${GREEN}✓ 最快镜像源: ${CYAN}${best_mirror}${NC} (${best_time}ms)"
        echo ""
        read -p "是否使用此镜像源? (y/n): " use_mirror
        
        if [[ "$use_mirror" =~ ^[Yy]$ ]]; then
            # 配置镜像源
            mkdir -p /etc/docker
            
            # 备份现有配置
            if [ -f "/etc/docker/daemon.json" ]; then
                cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)
            fi
            
            # 写入新配置
            if [ -f "/etc/docker/daemon.json" ] && [ -s "/etc/docker/daemon.json" ] && [ "$(cat /etc/docker/daemon.json)" != "{}" ]; then
                # 使用 jq 如果可用
                if command -v jq &> /dev/null; then
                    local tmp_file=$(mktemp)
                    jq --arg mirror "$best_mirror" '.["registry-mirrors"] = [$mirror]' /etc/docker/daemon.json > "$tmp_file"
                    mv "$tmp_file" /etc/docker/daemon.json
                else
                    # 简单替换或添加
                    if grep -q "registry-mirrors" /etc/docker/daemon.json; then
                        sed -i "s|\"registry-mirrors\":\s*\[[^]]*\]|\"registry-mirrors\": [\"$best_mirror\"]|g" /etc/docker/daemon.json
                    else
                        # 在文件开头添加
                        echo "{\"registry-mirrors\": [\"$best_mirror\"]}" > /etc/docker/daemon.json
                    fi
                fi
            else
                echo "{\"registry-mirrors\": [\"$best_mirror\"]}" > /etc/docker/daemon.json
            fi
            
            echo -e "${YELLOW}正在重启 Docker 服务...${NC}"
            if systemctl restart docker; then
                echo -e "${GREEN}✓ 镜像源配置成功！${NC}"
            else
                echo -e "${RED}Docker 重启失败，请检查配置${NC}"
            fi
        fi
    else
        echo -e "${RED}所有镜像源均不可用${NC}"
        echo -e "${YELLOW}可能是网络问题，请稍后重试${NC}"
    fi
    
    show_footer
}

# 17. Docker Compose 项目管理
manage_compose_projects() {
    while true; do
        clear_screen
        show_header "Docker Compose 项目管理"
        
        if ! command -v docker &> /dev/null; then
            echo -e "${RED}Docker 未安装${NC}"
            show_footer
            return 1
        fi
        
        # 检查 docker compose 是否可用
        local compose_cmd=""
        if docker compose version &>/dev/null; then
            compose_cmd="docker compose"
        elif command -v docker-compose &>/dev/null; then
            compose_cmd="docker-compose"
        else
            echo -e "${RED}Docker Compose 未安装${NC}"
            echo -e "${YELLOW}请先安装 Docker Compose${NC}"
            show_footer
            return 1
        fi
        
        echo -e "${BOLD} 📦 正在扫描 Compose 项目...${NC}"
        echo ""
        
        # 获取所有运行中的 compose 项目
        local projects=()
        local project_dirs=()
        
        # 方法1: 通过 docker compose ls 获取
        if docker compose ls &>/dev/null 2>&1; then
            echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"
            printf " ${BOLD}%-3s %-25s %-12s %s${NC}\n" "序号" "项目名称" "状态" "路径"
            echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"
            
            local idx=1
            while IFS= read -r line; do
                [[ "$line" == "NAME"* ]] && continue
                local name=$(echo "$line" | awk '{print $1}')
                local status=$(echo "$line" | awk '{print $2}')
                local dir=$(echo "$line" | awk '{print $3}')
                
                [[ -z "$name" ]] && continue
                
                projects+=("$name")
                project_dirs+=("$dir")
                
                local status_color="${GREEN}"
                [[ "$status" != "running"* ]] && status_color="${RED}"
                
                printf " %-3s %-25s ${status_color}%-12s${NC} %s\n" "$idx" "$name" "$status" "${dir:-未知}"
                ((idx++))
            done < <(docker compose ls 2>/dev/null)
            
            echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"
        fi
        
        if [ ${#projects[@]} -eq 0 ]; then
            echo -e "${YELLOW}未发现运行中的 Compose 项目${NC}"
            echo ""
            echo -e "${DIM}提示: 只有通过 docker compose up 启动的项目才会显示${NC}"
        fi
        
        echo ""
        echo -e "${BOLD} 操作菜单${NC}"
        show_menu_item "1" "启动项目 (up -d)"
        show_menu_item "2" "停止项目 (down)"
        show_menu_item "3" "重启项目 (restart)"
        show_menu_item "4" "查看项目日志"
        show_menu_item "5" "拉取项目镜像 (pull)"
        show_menu_item "6" "更新并重启项目"
        echo ""
        show_menu_item "0" "返回"
        echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
        
        read -p "$(echo -e ${YELLOW}"选择操作 [0-6]: "${NC})" choice
        
        case $choice in
            1|2|3|4|5|6)
                if [ ${#projects[@]} -eq 0 ]; then
                    read -p "请输入项目目录路径: " project_path
                    if [ ! -d "$project_path" ]; then
                        echo -e "${RED}目录不存在${NC}"
                        continue
                    fi
                    if [ ! -f "$project_path/docker-compose.yml" ] && [ ! -f "$project_path/docker-compose.yaml" ] && [ ! -f "$project_path/compose.yml" ] && [ ! -f "$project_path/compose.yaml" ]; then
                        echo -e "${RED}目录中没有找到 docker-compose 配置文件${NC}"
                        continue
                    fi
                else
                    read -p "请输入项目序号 (1-${#projects[@]}): " project_idx
                    if ! [[ "$project_idx" =~ ^[0-9]+$ ]] || [ "$project_idx" -lt 1 ] || [ "$project_idx" -gt ${#projects[@]} ]; then
                        echo -e "${RED}无效的序号${NC}"
                        continue
                    fi
                    project_path="${project_dirs[$((project_idx-1))]}"
                    # 如果路径为空，尝试查找
                    if [ -z "$project_path" ] || [ ! -d "$project_path" ]; then
                        local project_name="${projects[$((project_idx-1))]}"
                        # 尝试从容器标签获取项目路径
                        project_path=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' $(docker ps -q --filter "label=com.docker.compose.project=$project_name" | head -1) 2>/dev/null)
                    fi
                    
                    if [ -z "$project_path" ] || [ ! -d "$project_path" ]; then
                        read -p "请输入项目目录路径: " project_path
                    fi
                fi
                
                if [ ! -d "$project_path" ]; then
                    echo -e "${RED}目录不存在: $project_path${NC}"
                    read -p "按回车键继续..."
                    continue
                fi
                
                cd "$project_path" || continue
                
                case $choice in
                    1)
                        echo -e "${YELLOW}正在启动项目...${NC}"
                        $compose_cmd up -d
                        ;;
                    2)
                        echo -e "${YELLOW}正在停止项目...${NC}"
                        $compose_cmd down
                        ;;
                    3)
                        echo -e "${YELLOW}正在重启项目...${NC}"
                        $compose_cmd restart
                        ;;
                    4)
                        echo -e "${YELLOW}显示最近 50 行日志 (Ctrl+C 退出)${NC}"
                        $compose_cmd logs --tail=50 -f
                        ;;
                    5)
                        echo -e "${YELLOW}正在拉取镜像...${NC}"
                        $compose_cmd pull
                        ;;
                    6)
                        echo -e "${YELLOW}正在更新并重启...${NC}"
                        $compose_cmd pull
                        $compose_cmd up -d --remove-orphans
                        ;;
                esac
                
                cd - > /dev/null
                ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        
        [ "$choice" != "0" ] && [ "$choice" != "4" ] && read -p "$(echo -e ${YELLOW}"按回车键继续..."${NC})"
    done
}

#子菜单
# SSH配置子菜单
ssh_menu() {
    while true; do
        clear_screen
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD} 🔐 SSH 配置管理${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # SSH 状态概览
        local ssh_status="${RED}● 未运行${NC}"
        systemctl is-active --quiet sshd 2>/dev/null && ssh_status="${GREEN}● 运行中${NC}"
        systemctl is-active --quiet ssh 2>/dev/null && ssh_status="${GREEN}● 运行中${NC}"
        
        local ssh_port=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}')
        [ -z "$ssh_port" ] && ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
        [ -z "$ssh_port" ] && ssh_port="22"
        
        local pwd_auth=$(sshd -T 2>/dev/null | grep "passwordauthentication" | awk '{print $2}')
        local auth_method="${YELLOW}密码${NC}"
        [[ "$pwd_auth" == "no" ]] && auth_method="${GREEN}密钥${NC}"
        
        echo -e " 状态: ${ssh_status}   端口: ${CYAN}${ssh_port}${NC}   认证: ${auth_method}"
        echo ""
        
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
        show_menu_item "1" "修改SSH端口"
        show_menu_item "2" "配置SSH密钥认证"
        echo ""
        show_menu_item "0" "返回主菜单"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-2]: "${NC})" choice
        case $choice in
            1) modify_ssh_port ;;
            2) configure_ssh_key ;;
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
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD} 🛡️ UFW 防火墙配置${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # UFW 状态概览
        if ! command -v ufw &> /dev/null; then
            echo -e " 状态: ${RED}● 未安装${NC}"
        else
            local ufw_status=$(ufw status 2>/dev/null | head -1)
            if echo "$ufw_status" | grep -q "active"; then
                local rule_count=$(ufw status 2>/dev/null | grep -c "ALLOW\|DENY" || echo "0")
                echo -e " 状态: ${GREEN}● 运行中${NC}   规则数: ${CYAN}${rule_count}${NC}"
            else
                echo -e " 状态: ${YELLOW}● 已安装但未启用${NC}"
            fi
        fi
        echo ""
        
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
        show_menu_item "1" "安装UFW"
        show_menu_item "2" "配置UFW并开放SSH端口"
        show_menu_item "3" "配置UFW PING规则"
        show_menu_item "4" "查看UFW规则列表"
        show_menu_item "5" "开放端口到指定IP"
        show_menu_item "6" "批量端口管理"
        show_menu_item "7" "卸载UFW"
        echo ""
        show_menu_item "0" "返回主菜单"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-7]: "${NC})" choice
        case $choice in
            1) install_ufw ;;
            2) configure_ufw ;;
            3) configure_ufw_ping ;;
            4) check_ufw_status ;;
            5) open_port_to_ip ;;
            6) manage_batch_ports ;;
            7) uninstall_ufw ;;
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
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD} 🚫 Fail2ban 配置管理${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # Fail2ban 状态概览
        if ! command -v fail2ban-client &> /dev/null; then
            echo -e " 状态: ${RED}● 未安装${NC}"
        else
            local f2b_running=$(systemctl is-active fail2ban 2>/dev/null)
            if [ "$f2b_running" == "active" ]; then
                local jail_count=$(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk '{print $NF}')
                local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2 | xargs)
                echo -e " 状态: ${GREEN}● 运行中${NC}   监狱数: ${CYAN}${jail_count:-0}${NC}"
                [ -n "$jails" ] && echo -e " ${DIM}监狱: ${jails}${NC}"
            else
                echo -e " 状态: ${YELLOW}● 已安装但未运行${NC}"
            fi
        fi
        echo ""
        
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
        show_menu_item "1" "安装Fail2ban"
        show_menu_item "2" "配置Fail2ban SSH防护"
        show_menu_item "3" "查看Fail2ban状态"
        show_menu_item "4" "卸载Fail2ban"
        echo ""
        show_menu_item "0" "返回主菜单"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-4]: "${NC})" choice
        case $choice in
            1) install_fail2ban ;;
            2) configure_fail2ban_ssh ;;
            3) check_fail2ban_status ;;
            4) uninstall_fail2ban ;;
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
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD} 🌐 ZeroTier 配置管理${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # ZeroTier 状态概览
        if ! command -v zerotier-cli &> /dev/null; then
            echo -e " 状态: ${RED}● 未安装${NC}"
        else
            local zt_running=$(systemctl is-active zerotier-one 2>/dev/null)
            if [ "$zt_running" == "active" ]; then
                local zt_addr=$(zerotier-cli info 2>/dev/null | awk '{print $3}')
                local net_count=$(zerotier-cli listnetworks 2>/dev/null | grep -c "OK" || echo "0")
                echo -e " 状态: ${GREEN}● 运行中${NC}   地址: ${CYAN}${zt_addr:-未知}${NC}   网络数: ${net_count}"
            else
                echo -e " 状态: ${YELLOW}● 已安装但未运行${NC}"
            fi
        fi
        echo ""
        
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
        show_menu_item "1" "安装并加入网络"
        show_menu_item "2" "查看ZeroTier状态"
        show_menu_item "3" "配置ZeroTier SSH访问"
        show_menu_item "4" "卸载ZeroTier"
        echo ""
        show_menu_item "0" "返回主菜单"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-4]: "${NC})" choice
        case $choice in
            1) install_zerotier ;;
            2) check_zerotier_status ;;
            3) configure_zerotier_ssh ;;
            4) uninstall_zerotier ;;
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
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD} 🐳 Docker 配置管理${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # Docker 状态概览
        if ! command -v docker &> /dev/null; then
            echo -e " 状态: ${RED}● 未安装${NC}"
        else
            if docker info &> /dev/null 2>&1; then
                local docker_ver=$(docker --version 2>/dev/null | awk '{print $3}' | sed 's/,$//')
                local running=$(docker ps -q 2>/dev/null | wc -l)
                local total=$(docker ps -aq 2>/dev/null | wc -l)
                local images=$(docker images -q 2>/dev/null | wc -l)
                echo -e " 状态: ${GREEN}● 运行中${NC}   版本: ${CYAN}${docker_ver}${NC}"
                echo -e " 容器: ${CYAN}${running}/${total}${NC}   镜像: ${images}"
            else
                echo -e " 状态: ${YELLOW}● 已安装但未运行${NC}"
            fi
        fi
        echo ""
        
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
        # 基础配置 - 双列
        echo -e " ${BOLD}基础配置${NC}"
        echo -e "  ${YELLOW}01.${NC} ${GREEN}安装 Docker${NC}\t\t  ${YELLOW}02.${NC} ${GREEN}安装 Docker Compose${NC}"
        echo -e "  ${YELLOW}03.${NC} ${GREEN}配置镜像加速${NC}\t\t  ${YELLOW}04.${NC} ${GREEN}自动检测最快镜像源${NC}"
        
        # 网络配置 - 双列
        echo ""
        echo -e " ${BOLD}网络配置${NC}"
        echo -e "  ${YELLOW}05.${NC} ${GREEN}配置 UFW Docker 规则${NC}\t  ${YELLOW}06.${NC} ${GREEN}开放 Docker 端口${NC}"
        
        # 系统管理 - 双列
        echo ""
        echo -e " ${BOLD}系统管理${NC}"
        echo -e "  ${YELLOW}07.${NC} ${GREEN}查看容器信息${NC}\t\t  ${YELLOW}08.${NC} ${GREEN}容器管理${NC}"
        echo -e "  ${YELLOW}09.${NC} ${GREEN}Compose项目管理${NC}\t\t  ${YELLOW}10.${NC} ${GREEN}清理Docker资源${NC}"
        echo -e "  ${YELLOW}11.${NC} ${GREEN}查看网络信息${NC}\t\t  ${YELLOW}12.${NC} ${GREEN}卸载Docker${NC}"
        
        echo ""
        show_menu_item "0" "返回主菜单"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-12]: "${NC})" choice
        case $choice in
            1) install_docker ;;
            2) install_docker_compose ;;
            3) configure_docker_mirror ;;
            4) test_docker_mirrors ;;
            5) configure_ufw_docker ;;
            6) open_docker_port ;;
            7) show_docker_container_info ;;
            8) manage_containers ;;
            9) manage_compose_projects ;;
            10) clean_docker_resources ;;
            11) show_docker_networks ;;
            12) uninstall_docker ;;
            0) return ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
        [ "$choice" != "0" ] && read -p "$(echo -e ${YELLOW}"按回车键继续..."${NC})"
    done
}

# 网络设置菜单
network_settings_menu() {
    while true; do
        clear_screen
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD} 🌐 网络&时区设置${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # 获取网络信息
        local ipv4_addr=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -1)
        local ipv6_addr=$(ip -6 addr show 2>/dev/null | grep -oP '(?<=inet6\s)[\da-f:]+' | grep -v "::1" | head -1)
        local dns=$(grep nameserver /etc/resolv.conf 2>/dev/null | head -1 | awk '{print $2}')
        local timezone=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')
        
        # IPv6状态
        local ipv6_status="${GREEN}已启用${NC}"
        [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "1" ] && ipv6_status="${RED}已禁用${NC}"
        
        # BBR状态
        local bbr_status="${RED}未启用${NC}"
        sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr" && bbr_status="${GREEN}已启用${NC}"
        
        echo -e " ${CYAN}IPv4:${NC} ${ipv4_addr:-未检测到}   ${CYAN}IPv6:${NC} ${ipv6_status}"
        echo -e " ${CYAN}DNS:${NC} ${dns:-未配置}   ${CYAN}时区:${NC} ${timezone:-未知}   ${CYAN}BBR:${NC} ${bbr_status}"
        echo ""
        
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
        show_menu_item "1" "DNS修改"
        show_menu_item "2" "系统时区修改"
        show_menu_item "3" "网络诊断"
        show_menu_item "4" "IPv6设置"
        show_menu_item "5" "主机名和hosts文件管理"
        show_menu_item "6" "BBR 加速设置"
        echo ""
        show_menu_item "0" "返回主菜单"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-6]: "${NC})" choice
        
        case $choice in
            1) modify_dns ;;
            2) modify_timezone ;;
            3) network_diagnostic ;;
            4) ipv6_settings ;;
            5) hostname_hosts_menu ;;
            6) bbr_settings ;;
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
        show_dashboard
        
        echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
        echo -e "${BOLD} 🛠️  功能菜单${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
        
        # 系统管理 - 双列
        echo -e " ${CYAN}[系统管理]${NC}"
        echo -e "  ${YELLOW}01.${NC} ${GREEN}更新系统${NC}\t\t  ${YELLOW}02.${NC} ${GREEN}SSH配置${NC}"
        echo -e "  ${YELLOW}03.${NC} ${GREEN}UFW防火墙配置${NC}\t  ${YELLOW}04.${NC} ${GREEN}Fail2ban配置${NC}"
        echo -e "  ${YELLOW}05.${NC} ${GREEN}ZeroTier配置${NC}\t  ${YELLOW}06.${NC} ${GREEN}Docker配置${NC}"
        echo -e "  ${YELLOW}07.${NC} ${GREEN}Swap配置${NC}"
        
        # 系统工具 - 双列
        echo ""
        echo -e " ${CYAN}[系统工具]${NC}"
        echo -e "  ${YELLOW}10.${NC} ${GREEN}系统安全检查${NC}\t  ${YELLOW}11.${NC} ${GREEN}系统安全加固${NC}"
        echo -e "  ${YELLOW}12.${NC} ${GREEN}系统资源监控${NC}\t  ${YELLOW}13.${NC} ${GREEN}网络&时区设置${NC}"
        echo -e "  ${YELLOW}14.${NC} ${GREEN}端口扫描检测${NC}\t  ${YELLOW}15.${NC} ${GREEN}检查脚本更新${NC}"
        
        # 应用安装 - 双列
        echo ""
        echo -e " ${CYAN}[应用安装]${NC}"
        echo -e "  ${YELLOW}08.${NC} ${GREEN}1Panel安装${NC}\t  ${YELLOW}09.${NC} ${GREEN}v2ray-agent安装${NC}"
        
        echo -e ""
        show_menu_item "0" "退出系统"
        
        show_footer
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-15]: "${NC})" choice
        case $choice in
            1) system_update ;;
            2) ssh_menu ;;
            3) ufw_menu ;;
            4) fail2ban_menu ;;
            5) zerotier_menu ;;
            6) docker_menu ;;
            7) configure_swap ;;
            8) install_1panel ;;
            9) install_v2ray_agent ;;
            10) system_security_check ;;
            11) system_security_hardening ;;
            12) system_resource_monitor ;;
            13) network_settings_menu ;;
            14) port_scan_detection ;;
            15) check_script_update ;;
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

# 检查依赖
check_dependencies

# 运行主菜单
main_menu
    
