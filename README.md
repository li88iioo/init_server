## 懒人服务器安全配置脚本
```
wget -P /root -N --no-check-certificate https://raw.githubusercontent.com/li88iioo/init_server/refs/heads/main/init_server.sh && chmod 700 /root/init_server.sh && /root/init_server.sh
```

### 主要功能
![图片](https://github.com/user-attachments/assets/66bedcec-e8a5-4226-a47a-65183778c472)


1. **系统更新与工具安装**：
   - 执行系统更新并安装 `curl`（一个常用的命令行工具，用于进行 HTTP 请求）。
   
2. **SSH 配置**：
   - 修改 SSH 默认端口，避免暴力破解攻击。
   - 配置 SSH 密钥认证，禁用密码登录以增加 SSH 安全性。
   
3. **UFW 防火墙配置**：
   - 安装并配置 `UFW`（Uncomplicated Firewall），用来管理防火墙规则。
   - 设置 UFW 规则，允许特定端口（如 SSH 端口）访问，禁止 ICMP (PING) 请求。
   
4. **Fail2ban 安装与配置**：
   - 安装 `Fail2ban` 服务，防止暴力破解攻击。
   - 配置 Fail2ban 保护 SSH 服务。
   
5. **ZeroTier 配置**：
   - 安装 ZeroTier（一个虚拟局域网软件），并允许服务器加入一个 ZeroTier 网络。
   - 配置 ZeroTier 网络上的 SSH 访问。

6. **其他工具安装**：
   - 提供选项安装 **1Panel**（一个服务器管理面板）和 **v2ray-agent**（用于安装与管理 V2Ray）。
