##  一个用于快速配置和管理 Linux 服务器的懒人Shell 脚本

### 快速开始
```bash
wget -P /root -N --no-check-certificate https://raw.githubusercontent.com/li88iioo/init_server/refs/heads/main/init_server.sh && chmod 700 /root/init_server.sh && /root/init_server.sh
```
---

## 系统功能概览

### 系统管理
- **01. 更新系统** - 更新系统软件包和安全补丁
- **02. SSH配置** - 管理SSH服务安全设置和访问控制
- **03. UFW防火墙配置** - 配置Uncomplicated Firewall保护服务器
- **04. Fail2ban配置** - 设置防暴力破解策略
- **05. ZeroTier配置** - 管理虚拟网络连接
- **06. Docker配置** - 安装和管理Docker容器服务
- **07. Swap配置** - 配置系统交换空间

### 应用安装
- **08. 1Panel安装** - 安装轻量级服务器管理面板
- **09. v2ray-agent安装** - 搭建安全网络代理服务

### 系统工具
- **10. 系统安全检查** - 检查系统安全状态和运行信息
- **11. 系统安全加固** - 应用系统安全最佳实践
- **12. 系统资源监控** - 监控CPU、内存和磁盘使用情况
- **13. 网络设置** - 管理网络连接、DNS和时区设置

---

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
