![image](https://github.com/user-attachments/assets/b5a7fef8-0cf0-49e5-b297-f10126c1440b)
# 服务器配置管理系统

一个用于快速配置和管理 Linux 服务器的懒人Shell 脚本

### 快速开始
```bash
wget -P /root -N --no-check-certificate https://raw.githubusercontent.com/li88iioo/init_server/refs/heads/main/init_server.sh && chmod 700 /root/init_server.sh && /root/init_server.sh
```

## 功能特点

### 系统管理
- 系统更新与软件安装
- SSH 端口配置与安全加固
- UFW 防火墙配置
- Fail2ban 防暴力破解
- ZeroTier 虚拟网络配置
- Docker 环境配置
- Swap 交换空间管理

### 应用安装
- 1Panel 面板
- v2ray-agent

### 系统工具
- 系统安全检查
- 系统安全加固
- 系统资源监控
- 网络诊断

## 功能详解

### SSH 配置
- 修改 SSH 端口
- 配置 SSH 密钥认证
- SSH 安全加固

### 防火墙配置
- UFW 规则管理
- 端口开放/关闭
- PING 响应控制
- Docker 网络规则配置

### Fail2ban 配置
- SSH 防暴力破解
- 自定义封禁规则
- 状态监控

### Docker 管理
- Docker 环境安装
- Docker Compose 安装
- 容器资源监控
- 网络配置
- 资源清理

### Swap 管理
- 创建/调整 Swap 大小
- Swappiness 参数调整
- Swap 删除

### 系统监控
- CPU 使用率
- 内存使用情况
- 磁盘使用状态
- 网络连接状态

### 安全检查
- 系统基本信息检查
- 开放端口检查
- 登录记录审计
- SSH 配置检查
- 防火墙状态检查

## 使用建议

1. 首次使用建议先运行系统安全检查
2. 及时更新系统并配置防火墙
3. 配置 SSH 密钥认证并禁用密码登录
4. 根据需要调整 Swap 和系统参数
5. 定期检查系统资源使用情况

## 注意事项

- 脚本需要 root 权限运行
- 修改 SSH 配置前请确保有其他可用的登录方式
- 防火墙配置前请确保已开放必要端口
- 建议在配置前备份重要数据
- 部分功能可能需要联网下载相关组件

## 常见问题

**Q: 如何备份配置？**
A: 脚本会自动备份重要的配置文件，备份文件通常带有时间戳后缀。

**Q: 忘记修改后的 SSH 端口？**
A: 可以在 `/etc/ssh/sshd_config` 文件中查看。

**Q: 如何恢复被 Fail2ban 封禁的 IP？**
A: 使用 `fail2ban-client set sshd unbanip <IP>` 命令。
