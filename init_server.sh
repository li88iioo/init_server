#!/bin/bash

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户或使用 sudo 执行此脚本."
    exit 1
fi

# 步骤 1: 检查当前 SSH 服务的端口
CURRENT_SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
if [ -z "$CURRENT_SSH_PORT" ]; then
    CURRENT_SSH_PORT=22
fi

# 显示当前 SSH 端口
echo "当前 SSH 服务端口: $CURRENT_SSH_PORT"

# 询问用户要修改的 SSH 端口
read -p "请输入要修改的 SSH 端口号 (当前端口为 $CURRENT_SSH_PORT): " SSH_PORT

# 检查端口是否已经被占用
if ss -tnlp | grep -q ":$SSH_PORT "; then
    echo "错误: 端口 $SSH_PORT 已经被占用，请选择其他端口."
    exit 1
fi

# 步骤 2: 修改 SSH 配置文件
echo "正在修改 SSH 配置文件，设置端口为 $SSH_PORT..."
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config

# 步骤 3: 配置防火墙 (UFW)
echo "配置防火墙，允许端口 $SSH_PORT..."
ufw allow $SSH_PORT/tcp

# 删除默认的 SSH 端口 22 规则
if ufw status | grep -q "22/tcp"; then
    echo "删除防火墙中对端口 22 的允许规则..."
    ufw delete allow 22/tcp
fi

# 重新加载防火墙
echo "重新加载防火墙..."
ufw reload

# 步骤 4: 配置 Fail2ban
echo "正在配置 Fail2ban 以监听新的 SSH 端口 $SSH_PORT..."

# 检查是否存在 /etc/fail2ban/jail.local，如果没有则创建
if [ ! -f /etc/fail2ban/jail.local ]; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    echo "创建 jail.local 配置文件..."
fi

# 更新 Fail2ban 配置
sed -i "/\[sshd\]/,/^$/s/^#port =.*/port = $SSH_PORT/" /etc/fail2ban/jail.local

# 步骤 5: 重启 SSH 和 Fail2ban 服务
echo "重启 SSH 服务和 Fail2ban 服务..."
systemctl restart ssh
systemctl restart fail2ban

# 步骤 6: 检查 SSH 密钥是否存在
echo "检查 SSH 密钥是否存在..."

# 检查本地用户是否已有密钥对
if [ ! -f "$HOME/.ssh/id_rsa" ]; then
    echo "错误: 找不到本地私钥文件 ($HOME/.ssh/id_rsa)。请先生成 SSH 密钥对并确保配置正确。"
    exit 1
fi

# 检查本地公钥文件是否存在
if [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
    echo "错误: 找不到本地公钥文件 ($HOME/.ssh/id_rsa.pub)。请先生成 SSH 密钥对并确保配置正确。"
    exit 1
fi

# 提示用户确认是否开启单密钥登录
read -p "您是否想启用单密钥登录 (禁用密码登录)？(y/n): " ENABLE_KEY_LOGIN
if [[ "$ENABLE_KEY_LOGIN" =~ ^[Yy]$ ]]; then
    echo "正在启用单密钥登录（禁用密码登录）..."

    # 修改 SSH 配置文件
    sed -i "s/^#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#ChallengeResponseAuthentication yes/ChallengeResponseAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#UsePAM yes/UsePAM no/" /etc/ssh/sshd_config
    sed -i "s/^#PubkeyAuthentication yes/PubkeyAuthentication yes/" /etc/ssh/sshd_config

    # 重启 SSH 服务以应用更改
    systemctl restart ssh
fi

# 步骤 7: 安装和配置 ZeroTier
echo "正在安装 ZeroTier..."

# 更新系统包列表并安装 ZeroTier
apt update && apt upgrade -y
curl -s https://install.zerotier.com | sudo bash
apt install zerotier-one -y

# 启动 ZeroTier 服务
systemctl start zerotier-one
systemctl enable zerotier-one

# 提示用户加入 ZeroTier 网络
read -p "请输入 ZeroTier 网络 ID: " ZT_NETWORK_ID

# 加入 ZeroTier 网络
zerotier-cli join $ZT_NETWORK_ID

# 步骤 8: 手动输入 ZeroTier IP 段并配置防火墙
echo "请输入 ZeroTier 网络的 IP 段（例如：192.168.193.0/24）："
read ZT_IP_RANGE

echo "正在配置防火墙，允许来自 ZeroTier 网络 $ZT_IP_RANGE 的 SSH 流量..."

# 配置防火墙，允许 ZeroTier 网络 IP 段访问 SSH
ufw allow from $ZT_IP_RANGE to any port $SSH_PORT proto tcp

# 步骤 9: 显示当前配置
echo "==== 当前 SSH 配置 ===="
ss -tnlp | grep ssh
echo

echo "==== 当前 UFW 防火墙状态 ===="
ufw status
echo

echo "==== 当前 Fail2ban 状态 ===="
fail2ban-client status sshd
echo

# 步骤 10: 提示用户验证新的 SSH 端口和 SSH 密钥登录
echo "修改成功！请使用以下命令测试新的 SSH 端口:"
echo "ssh -p $SSH_PORT <your-username>@<your-server-ip>"
echo "确保您的 SSH 密钥已正确配置。"

# 步骤 11: 提示用户验证 ZeroTier 网络连接
echo "ZeroTier 配置完成，您已加入网络 $ZT_NETWORK_ID。"
echo "您可以通过以下命令查看 ZeroTier 网络接口:"
echo "ip a"
