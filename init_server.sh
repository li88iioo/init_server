#!/bin/bash

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# 处理Docker输出格式的函数
format_docker_output() {
    # 替换可能未正确解析的ANSI颜色码
    sed 's/33\[0;34m/\\033[0;34m/g' | sed 's/33\[0m/\\033[0m/g' | sed 's/\\033/\033/g' | sed 's/\\0\\033/\033/g' | sed 's/\\0\\0/\0/g'
}

# 分隔线
show_separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 添加新的样式函数
show_header() {
    local title="$1"
    echo -e "\n${BLUE}┏${BOLD}$title${NC}${BLUE}          ${NC}"
}

show_footer() {
    echo -e "${BLUE}                              ${NC}\n"
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
    
    # 确保UFW服务启用并启动
    systemctl enable ufw
    
    # 尝试启动UFW
    if ! systemctl start ufw; then
        echo -e "${YELLOW}UFW服务首次启动失败，尝试重新启动...${NC}"
        systemctl restart ufw
    fi
    
    # 验证UFW状态
    if systemctl is-active --quiet ufw; then
        success_msg "UFW已安装并成功启动"
    else
        # 如果仍未启动，尝试重置UFW并重新启动
        echo -e "${YELLOW}UFW启动失败，尝试重置并重新启动...${NC}"
        ufw reset
        systemctl restart ufw
        
        if systemctl is-active --quiet ufw; then
            success_msg "UFW已重置并成功启动"
        else
            echo -e "${RED}UFW无法启动，请手动检查：systemctl status ufw${NC}"
            return 1
        fi
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
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}请先安装UFW${NC}"
        return 1
    fi
    
    echo "UFW状态:"
    ufw status verbose
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
            ufw allow proto tcp from $ip_address to any port $port
            ufw allow proto udp from $ip_address to any port $port
            success_msg "已开放端口 $port 的TCP和UDP协议给IP $ip_address"
        else
            ufw allow proto $protocol from $ip_address to any port $port
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
    show_header "UFW 批量端口管理"
    
    # 验证UFW是否已安装
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}请先安装UFW${NC}"
        return 1
    fi
    
    echo -e "${BLUE}请选择操作:${NC}"
    echo "1. 批量开放端口"
    echo "2. 批量关闭端口"
    echo "3. 批量开放端口到特定IP"
    echo "4. 批量删除UFW规则"
    echo "0. 返回"
    
    read -p "选择操作 [0-4]: " batch_choice
    
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
    
    # 获取并显示所有规则
    ufw status numbered | grep -v "Status:"
    # 使用更灵活的正则表达式匹配带编号的规则
    mapfile -t rules < <(ufw status numbered | grep -E '^\[[ 0-9]+\]')
    
    if [ ${#rules[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有找到任何UFW规则${NC}"
        read -p "按回车键返回..." -r
        return
    fi
    
    # 显示规则列表
    for i in "${!rules[@]}"; do
        echo -e "${GREEN}$((i+1))${NC}: ${rules[$i]}"
    done
    
    echo ""
    echo -e "${YELLOW}删除选项:${NC}"
    echo "1. 按范围删除规则"
    echo "2. 按规则号删除多条规则"
    echo "0. 返回"
    
    read -p "选择操作 [0-2]: " delete_choice
    
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
                    yes | ufw delete $rule_num
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
                    yes | ufw delete $rule_num
                done
                echo -e "${GREEN}批量删除完成${NC}"
            else
                echo -e "${YELLOW}操作已取消${NC}"
            fi
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
                if ufw allow proto tcp from $ip_address to any port $port && \
                   ufw allow proto udp from $ip_address to any port $port; then
                    echo -e "${GREEN}已开放端口 $port (TCP/UDP) 到IP $ip_address${NC}"
                    ((success_count++))
                else
                    echo -e "${RED}开放端口 $port 到IP $ip_address 失败${NC}"
                    failed_ports="$failed_ports,$port"
                fi
            else
                if ufw allow proto $protocol from $ip_address to any port $port; then
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

#  Fail2ban配置
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
        echo -e "${BLUE}┃${NC} ${RED}Docker 未安装，请先安装 Docker${NC}"
        show_footer
        return 1
    fi
    
    echo -e "${BLUE}┃${NC} ${BOLD}Docker 镜像加速配置${NC}"
    echo -e "${BLUE}┃${NC}"
    
    # 检查当前配置
    if [ -f "/etc/docker/daemon.json" ]; then
        echo -e "${BLUE}┃${NC} ${GREEN}当前配置的镜像加速:${NC}"
        echo -e "${BLUE}┃${NC}"
        # 提取镜像URL并以简单格式显示
        mirrors=$(grep -o '"https://[^"]*"' /etc/docker/daemon.json)
        if [ -n "$mirrors" ]; then
            echo "$mirrors" | sed 's/"//g' | while read -r url; do
                echo -e "${BLUE}┃${NC}  • $url"
            done
        else
            echo -e "${BLUE}┃${NC}  无法解析镜像URL，查看原始配置:"
            cat /etc/docker/daemon.json | while read -r line; do
                echo -e "${BLUE}┃${NC}    $line"
            done
        fi
        echo -e "${BLUE}┃${NC}"
    else
        echo -e "${BLUE}┃${NC} ${YELLOW}当前未配置镜像加速${NC}"
        echo -e "${BLUE}┃${NC}"
    fi
    
    echo -e "${BLUE}┃${NC} 1) 配置镜像加速"
    echo -e "${BLUE}┃${NC} 2) 删除镜像加速配置"
    echo -e "${BLUE}┃${NC} 0) 返回上级菜单"
    echo -e "${BLUE}┃${NC}"
    
    read -p "$(echo -e ${BLUE}"┃${NC} "${YELLOW}"请选择操作 [0-2]: "${NC})" choice
    
    case $choice in
        1)
            echo -e "${BLUE}┃${NC}"
            echo -e "${BLUE}┃${NC} 请输入您要使用的 Docker 镜像加速地址:"
            read -p "$(echo -e ${BLUE}"┃${NC} "${YELLOW}"> "${NC})" mirror_url
            
            if [ -z "$mirror_url" ]; then
                echo -e "${BLUE}┃${NC} ${RED}未提供镜像加速地址，操作取消${NC}"
                show_footer
                return 1
            fi
            
            # 创建或更新daemon.json文件
            mkdir -p /etc/docker
            
            # 测试镜像配置开始
            echo -e "${BLUE}┃${NC} ${YELLOW}正在测试镜像地址有效性...${NC}"
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
                echo -e "${BLUE}┃${NC} ${RED}使用此镜像地址无法启动Docker，可能是镜像地址无效${NC}"
                echo -e "${BLUE}┃${NC} ${YELLOW}正在恢复原配置...${NC}"
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
            echo -e "${BLUE}┃${NC} ${GREEN}镜像地址测试通过!${NC}"
            
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
            echo -e "${BLUE}┃${NC} ${YELLOW}正在应用配置并重启Docker服务...${NC}"
            show_loading "正在重启Docker" 30
            systemctl restart docker
            echo -e "${BLUE}┃${NC} ${GREEN}已配置Docker镜像加速并重启Docker服务${NC}"
            echo -e "${BLUE}┃${NC} ${GREEN}镜像加速地址: ${mirror_url}${NC}"
            ;;
        2)
            # 删除镜像加速配置
            if [ -f "/etc/docker/daemon.json" ]; then
                # 创建备份
                cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)
                
                # 简单地创建一个空的配置文件
                echo '{}' > /etc/docker/daemon.json
                
                # 重启Docker服务
                echo -e "${BLUE}┃${NC} ${YELLOW}正在重启Docker服务...${NC}"
                show_loading "等待Docker服务重启" 5
                
                if systemctl restart docker; then
                    echo -e "${BLUE}┃${NC} ${GREEN}已删除镜像加速配置并重启Docker服务${NC}"
                else
                    echo -e "${BLUE}┃${NC} ${RED}Docker服务重启失败，恢复备份...${NC}"
                    # 恢复最近的备份
                    cp "$(ls -t /etc/docker/daemon.json.bak.* | head -1)" /etc/docker/daemon.json
                    show_loading "正在恢复原配置" 3
                    systemctl restart docker
                    echo -e "${BLUE}┃${NC} ${YELLOW}已恢复备份${NC}"
                fi
            else
                echo -e "${BLUE}┃${NC} ${YELLOW}未发现镜像加速配置${NC}"
            fi
            ;;
        0) 
            # 返回上级菜单
            ;;
        *) 
            echo -e "${BLUE}┃${NC} ${RED}无效的选择${NC}"
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
    
    # 手动打印标题行
    printf "${BLUE}┃${NC} %-12s %-25s %-40s %-s\n" "CONTAINER ID" "NAMES" "IMAGE" "STATUS"
    
    # 使用printf精确控制列宽和对齐
    docker ps -a --format "{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}" | \
    while IFS='|' read -r id name image status; do
        # 使用短ID (前12个字符)
        short_id="${id:0:12}"
        printf "${BLUE}┃${NC} %-12s %-25s %-40s %-s\n" "$short_id" "$name" "$image" "$status"
    done
    
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
            
            # 添加端口映射信息
            ports=$(docker port "$container_id" 2>/dev/null)
            if [[ -n "$ports" ]]; then
                echo -e "${BLUE}┃${NC}  ${GREEN}端口映射:${NC}"
                echo "$ports" | while read port_line; do
                    echo -e "${BLUE}┃${NC}    • $port_line"
                done
            else
                echo -e "${BLUE}┃${NC}  ${GREEN}端口映射:${NC} ${YELLOW}无暴露端口${NC}"
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
    docker system df | awk '{print "'"${BLUE}"'┃'"${NC}"' " $0}' | format_docker_output
    
    show_footer
}

# 容器管理函数
manage_containers() {
    while true; do
        clear_screen
        show_header "Docker 容器管理"
        
        # 检查是否安装了 Docker
        if ! command -v docker &> /dev/null; then
            echo -e "${BLUE}┃${NC} ${RED}Docker 未安装，无法管理容器${NC}"
            show_footer
            return 1
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
        
        # 手动打印标题行
        printf "${BLUE}┃${NC} %-12s %-25s %-40s %-s\n" "CONTAINER ID" "NAMES" "IMAGE" "STATUS"
        
        # 使用printf精确控制列宽和对齐
        container_count=0
        container_ids=()
        container_names=()
        
        while IFS='|' read -r id name image status; do
            if [ -n "$id" ]; then
                container_count=$((container_count + 1))
                container_ids+=("$id")
                container_names+=("$name")
                
                # 使用短ID (前12个字符)
                short_id="${id:0:12}"
                printf "${BLUE}┃${NC} %-12s %-25s %-40s %-s\n" "$short_id" "$name" "$image" "$status"
            fi
        done < <(docker ps -a --format "{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}")
        
        # 如果没有容器，显示提示
        if [ $container_count -eq 0 ]; then
            echo -e "${BLUE}┃${NC} ${YELLOW}当前没有任何容器${NC}"
        fi
        
        echo -e "${BLUE}┃${NC}"
        echo -e "${BLUE}┣━━ ${BOLD}容器操作${NC}"
        echo -e "${BLUE}┃${NC}"
        show_menu_item "1" "启动容器"
        show_menu_item "2" "停止容器"
        show_menu_item "3" "重启容器"
        show_menu_item "4" "暂停容器"
        show_menu_item "5" "恢复容器"
        show_menu_item "6" "删除容器"
        echo -e "${BLUE}┃${NC}"
        show_menu_item "0" "返回上级菜单"
        
        show_footer
        
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
                echo -e "${BLUE}┃${NC}"
                echo -e "${BLUE}┣━━ ${BOLD}请选择要操作的容器:${NC}"
                echo -e "${BLUE}┃${NC}"

                # 使用颜色交替显示容器
                for i in $(seq 0 $((container_count-1))); do
                    # 交替使用不同的颜色显示
                    if [ $((i % 2)) -eq 0 ]; then
                        echo -e "${BLUE}┃${NC} ${GREEN}$((i+1))${NC}) ${container_names[$i]} (${container_ids[$i]:0:12})"
                    else
                        echo -e "${BLUE}┃${NC} ${YELLOW}$((i+1))${NC}) ${container_names[$i]} (${container_ids[$i]:0:12})"
                    fi
                done

                echo -e "${BLUE}┃${NC}"
                echo -e "${BLUE}┃${NC} ${RED}0${NC}) 取消操作"
                
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
    docker network ls | awk '{print "'"${BLUE}"'┃'"${NC}"' " $0}' | format_docker_output
    
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

# 7. Swap 配置函数     
configure_swap() {
    clear_screen
    show_header "Swap 配置管理"
    
    # 显示当前 Swap 状态
    echo -e "${BLUE}┃${NC} ${BOLD}当前 Swap 状态：${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(free -h | grep -i swap)
    
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}Swap 文件信息：${NC}"
    echo -e "${BLUE}┃${NC}"
    if [ -f /swapfile ]; then
        while IFS= read -r line; do
            echo -e "${BLUE}┃${NC} $line"
        done < <(ls -lh /swapfile)
    else
        echo -e "${BLUE}┃${NC} ${YELLOW}未检测到 Swap 文件${NC}"
    fi
    
    echo -e "${BLUE}┃${NC}"
    show_menu_item "1" "创建/调整 Swap"
    show_menu_item "2" "删除 Swap"
    show_menu_item "3" "调整 Swappiness"
    echo -e "${BLUE}┃${NC}"
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
        curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh && bash quick_start.sh
    fi
}

# 9. v2ray-agent安装
install_v2ray_agent() {
    read -p "是否安装v2ray-agent? (y/n): " answer
    if [ "$answer" = "y" ]; then
        wget -P /root -N --no-check-certificate https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh && chmod 700 /root/install.sh && /root/install.sh
    fi
}

# 10.系统安全检查函数
system_security_check() {
    clear_screen
    show_header "系统安全检查"
    
    # 系统启动和运行时间
    echo -e "${BLUE}┃${NC} ${BOLD}1. 系统运行信息${NC}"
    echo -e "${BLUE}┃${NC}"
    # 系统启动时间
    boot_time=$(who -b | awk '{print $3, $4}')
    echo -e "${BLUE}┃${NC} ${YELLOW}系统启动时间:${NC} ${WHITE}${boot_time}${NC}"
    
    # 系统运行时间
    uptime_info=$(uptime -p)
    echo -e "${BLUE}┃${NC} ${YELLOW}系统运行时间:${NC} ${WHITE}${uptime_info}${NC}"
    
    # 系统基本信息
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}2. 系统基本信息${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(uname -a)
    
    # 当前登录用户
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}3. 当前登录用户${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(whoami)
    
    # 开放端口
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}4. 开放端口及监听服务${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(netstat -tuln | grep -E ":22\s|:80\s|:443\s")
    
    # 系统更新
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}5. 系统更新状态${NC}"
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
    echo -e "${BLUE}┣━━ ${BOLD}6. 最近登录记录${NC}"
    echo -e "${BLUE}┃${NC}"
    while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done < <(last -a | head -n 5)
    
    # 登录失败尝试
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}7. 最近登录失败尝试${NC}"
    echo -e "${BLUE}┃${NC}"
    if [ -f /var/log/auth.log ]; then
        while IFS= read -r line; do
            echo -e "${BLUE}┃${NC} $line"
        done < <(grep "Failed password" /var/log/auth.log | tail -5)
    elif [ -f /var/log/secure ]; then
        while IFS= read -r line; do
            echo -e "${BLUE}┃${NC} $line"
        done < <(grep "Failed password" /var/log/secure | tail -5)
    else
        echo -e "${BLUE}┃${NC} ${RED}无法找到认证日志文件${NC}"
    fi
    
    # SSH配置
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}8. SSH 安全配置${NC}"
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
    echo -e "${BLUE}┣━━ ${BOLD}9. 防火墙状态${NC}"
    echo -e "${BLUE}┃${NC}"
    if command -v ufw &> /dev/null; then
        while IFS= read -r line; do
            echo -e "${BLUE}┃${NC} $line"
        done < <(ufw status)
    else
        echo -e "${BLUE}┃${NC} ${YELLOW}UFW 未安装${NC}"
    fi
    
    # Fail2ban状态
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}10. Fail2ban状态${NC}"
    echo -e "${BLUE}┃${NC}"
    if command -v fail2ban-client &> /dev/null; then
        while IFS= read -r line; do
            echo -e "${BLUE}┃${NC} $line"
        done < <(fail2ban-client status | head -10)
    else
        echo -e "${BLUE}┃${NC} ${YELLOW}Fail2ban未安装${NC}"
    fi
    
    
    # 安全总结
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}13. 安全总结与建议${NC}"
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┃${NC} ${GREEN}系统安全检查完成${NC}"
    echo -e "${BLUE}┃${NC} ${YELLOW}建议:${NC}"
    echo -e "${BLUE}┃${NC} 1. 确保防火墙正常运行并配置适当的规则"
    echo -e "${BLUE}┃${NC} 2. 确保Fail2ban正常运行以防止暴力攻击"
    echo -e "${BLUE}┃${NC} 3. 定期更新系统和软件包"
    echo -e "${BLUE}┃${NC} 4. 监控异常登录活动"
    echo -e "${BLUE}┃${NC} 5. 保持足够的磁盘空间"
    
    show_footer
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

# 13. 网络设置相关函数
# 13-1 DNS修改函数
modify_dns() {
    clear_screen
    show_header "DNS修改"
    
    echo -e "${BLUE}┃ ${YELLOW}当前DNS服务器:${NC}"
    cat /etc/resolv.conf | grep nameserver
    
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}常用DNS服务器${NC}"
    echo -e "${BLUE}┃ ${WHITE}1. Google DNS (8.8.8.8, 8.8.4.4)${NC}"
    echo -e "${BLUE}┃ ${WHITE}2. Cloudflare DNS (1.1.1.1, 1.0.0.1)${NC}"
    echo -e "${BLUE}┃ ${WHITE}3. 阿里DNS (223.5.5.5, 223.6.6.6)${NC}"
    echo -e "${BLUE}┃ ${WHITE}4. 自定义DNS${NC}"
    echo -e "${BLUE}┃ ${WHITE}0. 返回${NC}"
    echo -e "${BLUE}┃${NC}"
    
    read -p "$(echo -e ${YELLOW}"请选择 [0-4]: "${NC})" choice
    
    case $choice in
        1) 
            echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
            echo "nameserver 8.8.4.4" | sudo tee -a /etc/resolv.conf > /dev/null
            echo -e "${GREEN}已设置为Google DNS${NC}"
            ;;
        2) 
            echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null
            echo "nameserver 1.0.0.1" | sudo tee -a /etc/resolv.conf > /dev/null
            echo -e "${GREEN}已设置为Cloudflare DNS${NC}"
            ;;
        3) 
            echo "nameserver 223.5.5.5" | sudo tee /etc/resolv.conf > /dev/null
            echo "nameserver 223.6.6.6" | sudo tee -a /etc/resolv.conf > /dev/null
            echo -e "${GREEN}已设置为阿里DNS${NC}"
            ;;
        4)
            read -p "$(echo -e ${YELLOW}"请输入主DNS服务器IP: "${NC})" primary_dns
            read -p "$(echo -e ${YELLOW}"请输入备用DNS服务器IP(可留空): "${NC})" secondary_dns
            
            echo "nameserver $primary_dns" | sudo tee /etc/resolv.conf > /dev/null
            if [ -n "$secondary_dns" ]; then
                echo "nameserver $secondary_dns" | sudo tee -a /etc/resolv.conf > /dev/null
            fi
            echo -e "${GREEN}DNS设置已更新${NC}"
            ;;
        0) return ;;
        *) echo -e "${RED}无效的选择${NC}" ;;
    esac
}

# 13-2 系统时区修改函数
modify_timezone() {
    clear_screen
    show_header "系统时区修改"
    
    echo -e "${BLUE}┃ ${YELLOW}当前时区:${NC}"
    timedatectl | grep "Time zone"
    
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}常用时区${NC}"
    echo -e "${BLUE}┃ ${WHITE}1. 亚洲/上海 (Asia/Shanghai)${NC}"
    echo -e "${BLUE}┃ ${WHITE}2. 亚洲/香港 (Asia/Hong_Kong)${NC}"
    echo -e "${BLUE}┃ ${WHITE}3. 亚洲/东京 (Asia/Tokyo)${NC}"
    echo -e "${BLUE}┃ ${WHITE}4. 美国/洛杉矶 (America/Los_Angeles)${NC}"
    echo -e "${BLUE}┃ ${WHITE}5. 美国/纽约 (America/New_York)${NC}"
    echo -e "${BLUE}┃ ${WHITE}6. 欧洲/伦敦 (Europe/London)${NC}"
    echo -e "${BLUE}┃ ${WHITE}7. 自定义时区${NC}"
    echo -e "${BLUE}┃ ${WHITE}0. 返回${NC}"
    echo -e "${BLUE}┃${NC}"
    
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
    
    echo -e "${GREEN}时区已更新为: $(timedatectl | grep 'Time zone' | awk '{print $3}')${NC}"
}


# 13-3 网络诊断函数
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
    
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┃ ${YELLOW}${current_status}${NC}"
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┣━━ ${BOLD}IPv6选项${NC}"
    echo -e "${BLUE}┃${NC}"
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

# 13-5 主机名和hosts文件管理菜单
hostname_hosts_menu() {
    while true; do
        clear_screen
        show_header "主机名和hosts文件管理"
        
        # 显示当前主机名
        current_hostname=$(hostname)
        echo -e "${BLUE}┃ ${YELLOW}当前主机名: ${WHITE}${current_hostname}${NC}"
        echo -e "${BLUE}┃${NC}"
        
        echo -e "${BLUE}┣━━ ${BOLD}管理选项${NC}"
        echo -e "${BLUE}┃${NC}"
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
    echo -e "${BLUE}┃ ${YELLOW}当前主机名: ${WHITE}${current_hostname}${NC}"
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┃ ${YELLOW}请输入新的主机名:${NC}"
    echo -e "${BLUE}┃${NC}"
    
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
    
    echo -e "${BLUE}┃ ${YELLOW}添加自定义域名映射到hosts文件${NC}"
    echo -e "${BLUE}┃${NC}"
    echo -e "${BLUE}┃ ${WHITE}格式: IP地址 域名${NC}"
    echo -e "${BLUE}┃ ${WHITE}例如: 192.168.1.100 myserver.local${NC}"
    echo -e "${BLUE}┃${NC}"
    
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
    
    echo -e "${BLUE}┃${NC}"
    cat /etc/hosts | while IFS= read -r line; do
        echo -e "${BLUE}┃${NC} $line"
    done
    echo -e "${BLUE}┃${NC}"
    
    # 添加选项删除特定映射
    echo -e "${BLUE}┣━━ ${BOLD}操作选项${NC}"
    echo -e "${BLUE}┃${NC}"
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

#子菜单
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
        show_menu_item "5" "开放端口到指定IP"
        show_menu_item "6" "批量端口管理"
        
    echo -e "${BLUE}┃${NC}"
        show_menu_item "0" "返回主菜单"
        
        show_footer
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-6]: "${NC})" choice
        case $choice in
            1) install_ufw ;;
            2) configure_ufw ;;
            3) configure_ufw_ping ;;
            4) check_ufw_status ;;
            5) open_port_to_ip ;;
            6) manage_batch_ports ;;
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
        show_menu_item "3" "配置镜像加速"
        
        echo -e "${BLUE}┃${NC}"
        echo -e "${BLUE}┣━━ ${BOLD}网络配置${NC}"
        show_menu_item "4" "配置 UFW Docker 规则"
        show_menu_item "5" "开放 Docker 端口"
        
        echo -e "${BLUE}┃${NC}"
        echo -e "${BLUE}┣━━ ${BOLD}系统管理${NC}"
        show_menu_item "6" "查看 Docker 容器信息"
        show_menu_item "7" "容器管理(启动/停止/重启/删除)"
        show_menu_item "8" "清理 Docker 资源"
        show_menu_item "9" "查看 Docker 网络信息"
        
        echo -e "${BLUE}┃${NC}"
        show_menu_item "0" "返回主菜单"
        
        show_footer
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-9]: "${NC})" choice
        case $choice in
            1) install_docker ;;
            2) install_docker_compose ;;
            3) configure_docker_mirror ;;
            4) configure_ufw_docker ;;
            5) open_docker_port ;;
            6) show_docker_container_info ;;
            7) manage_containers ;;
            8) clean_docker_resources ;;
            9) show_docker_networks ;;
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
        show_header "网络设置"
        
        # 显示当前服务器IP地址
        echo -e "${BLUE}┃${NC}"
        echo -e "${BLUE}┣━━ ${BOLD}服务器网络信息${NC}"
        
        # 获取IPv4地址(本地接口)
        pv4_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -1)

        # 获取公网IPv4地址
        if command -v curl &> /dev/null; then
            public_ipv4=$(curl -s ipinfo.io/ip 2>/dev/null)
    
        # 检查是否获取到公网IP
        if [ -n "$public_ipv4" ] && [ "$ipv4_addr" != "$public_ipv4" ]; then
            echo -e "${BLUE}┃ ${YELLOW}内网IPv4地址: ${WHITE}${ipv4_addr:-未检测到}${NC}"
            echo -e "${BLUE}┃ ${YELLOW}公网IPv4地址: ${WHITE}${public_ipv4}${NC}"
        else
            echo -e "${BLUE}┃ ${YELLOW}IPv4地址: ${WHITE}${ipv4_addr:-未检测到}${NC}"
        fi
    else
    echo -e "${BLUE}┃ ${YELLOW}IPv4地址: ${WHITE}${ipv4_addr:-未检测到}${NC}"
    echo -e "${BLUE}┃ ${YELLOW}公网IPv4地址: ${RED}未检测到 (需要安装curl)${NC}"
    fi
        # 获取IPv6地址
        ipv6_addr=$(ip -6 addr show | grep -oP '(?<=inet6\s)[\da-f:]+'| grep -v "::1" | head -1)
        echo -e "${BLUE}┃ ${YELLOW}IPv6地址: ${WHITE}${ipv6_addr:-未检测到}${NC}"
        
        # 检查IPv6状态
        ipv6_status="已启用"
        if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == "1" ]; then
            ipv6_status="已禁用"
        fi
        echo -e "${BLUE}┃ ${YELLOW}IPv6状态: ${WHITE}${ipv6_status}${NC}"
        
        echo -e "${BLUE}┃${NC}"
        echo -e "${BLUE}┣━━ ${BOLD}网络设置选项${NC}"
        echo -e "${BLUE}┃${NC}"
        show_menu_item "1" "DNS修改"
        show_menu_item "2" "系统时区修改"
        show_menu_item "3" "网络诊断"
        show_menu_item "4" "IPv6设置"
        show_menu_item "5" "主机名和hosts文件管理"
        show_menu_item "0" "返回主菜单"
        
        show_footer
        
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-4]: "${NC})" choice
        
        case $choice in
            1) modify_dns ;;
            2) modify_timezone ;;
            3) network_diagnostic ;;
            4) ipv6_settings ;;
            5) hostname_hosts_menu ;;
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
        
        echo -e "${BLUE}┃${NC}"
        echo -e "${BLUE}┣━━ ${BOLD}系统管理${NC}"
        show_menu_item "01" "更新系统"
        show_menu_item "02" "SSH配置"
        show_menu_item "03" "UFW防火墙配置"
        show_menu_item "04" "Fail2ban配置"
        show_menu_item "05" "ZeroTier配置"
        show_menu_item "06" "Docker配置"
        show_menu_item "07" "Swap配置"
        
        echo -e "${BLUE}┃${NC}"
        echo -e "${BLUE}┣━━ ${BOLD}应用安装${NC}"
        show_menu_item "08" "1Panel安装"
        show_menu_item "09" "v2ray-agent安装"
        
        echo -e "${BLUE}┃${NC}"
        echo -e "${BLUE}┣━━ ${BOLD}系统工具${NC}"
        show_menu_item "10" "系统安全检查"
        show_menu_item "11" "系统安全加固"
        show_menu_item "12" "系统资源监控"
        show_menu_item "13" "网络设置"
        
        echo -e "${BLUE}┃${NC}"
        show_menu_item "0" "退出系统"
        
        show_footer
        
        # 显示服务器时区和时间
        current_timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')
        current_time=$(date "+%Y-%m-%d %H:%M:%S")
        echo -e "${GREEN}服务器时区: ${current_timezone} ${WHITE}| ${CYAN}当前时间: ${current_time}${NC}"  
              
        read -p "$(echo -e ${YELLOW}"请选择操作 [0-13]: "${NC})" choice
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
    
